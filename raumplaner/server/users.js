import { dummyVerify, hashPassword, publicUser, randomToken, RateLimiter, verifyPassword } from './auth.js';
import { badRequest, conflict, forbidden, notFound, unauthorized } from './errors.js';
import { password as checkPassword, reqEmail, reqString, toBool, toId, toInt } from './validate.js';

const REMINDER_CHOICES = [0, 5, 10, 15, 30, 60, 120, 1440];

export class UserService {
  constructor(ctx) {
    this.ctx = ctx;
    const window = 15 * 60000;
    // Großzügig pro IP (mehrere Personen können sich eine IP teilen), streng pro Konto
    this.ipLimiter = new RateLimiter({ limit: 100, windowMs: window, clock: ctx.clock });
    this.emailLimiter = new RateLimiter({ limit: 10, windowMs: window, clock: ctx.clock });
  }

  get db() {
    return this.ctx.db;
  }

  count() {
    return this.db.get('SELECT COUNT(*) AS n FROM users').n;
  }

  byId(id) {
    return this.db.get('SELECT * FROM users WHERE id = ?', [id]);
  }

  byEmail(email) {
    return this.db.get('SELECT * FROM users WHERE email = ?', [email]);
  }

  calendarUrl(user) {
    return `${this.ctx.config.publicUrl}/cal/${user.calendar_token}.ics`;
  }

  async create({ name, email, password, role = 'user' }) {
    const cleanName = reqString(name, 'Name', { max: 100 });
    const cleanEmail = reqEmail(email);
    checkPassword(password);
    if (this.byEmail(cleanEmail)) throw conflict('Für diese E-Mail-Adresse gibt es bereits ein Konto.');
    const hash = await hashPassword(password);
    const now = this.ctx.clock.now();
    const reminder = this.ctx.settings.get('default_reminder_minutes');
    let r;
    try {
      r = this.db.run(
        `INSERT INTO users (email, name, password_hash, role, reminder_minutes, calendar_token, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        [cleanEmail, cleanName, hash, role === 'admin' ? 'admin' : 'user', reminder, randomToken(24), now],
      );
    } catch (err) {
      // Zwei gleichzeitige Registrierungen mit derselben Adresse
      if (/UNIQUE constraint failed: users\.email/.test(err.message)) throw conflict('Für diese E-Mail-Adresse gibt es bereits ein Konto.');
      throw err;
    }
    return this.byId(r.lastInsertRowid);
  }

  /** Ersteinrichtung: legt das erste Administrator-Konto an. */
  async setup({ orgName, name, email, password }) {
    if (this.count() > 0 || this.setupRunning) throw forbidden('Die Ersteinrichtung wurde bereits durchgeführt.');
    this.setupRunning = true; // verhindert zwei gleichzeitige Ersteinrichtungen (Hashing ist asynchron)
    try {
      const user = await this.create({ name, email, password, role: 'admin' });
      if (orgName) this.ctx.settings.update({ org_name: orgName });
      this.ctx.audit(user.id, 'setup', `Administrator ${user.email} angelegt`);
      return user;
    } finally {
      this.setupRunning = false;
    }
  }

  async register({ name, email, password }, ip = 'unbekannt') {
    this.ipLimiter.check(`register:${ip}`);
    this.ipLimiter.hit(`register:${ip}`);
    if (!this.ctx.settings.get('allow_registration')) {
      throw forbidden('Die Selbstregistrierung ist deaktiviert. Bitte wende dich an die Administration.');
    }
    const cleanEmail = reqEmail(email);
    if (!this.ctx.settings.emailDomainAllowed(cleanEmail)) {
      throw forbidden(`Registrierung nur mit einer Firmen-Adresse möglich (${this.ctx.settings.get('allowed_email_domains')}).`);
    }
    const user = await this.create({ name, email: cleanEmail, password, role: 'user' });
    this.ctx.audit(user.id, 'user.register', user.email);
    return user;
  }

  async login({ email, password }, ip) {
    const cleanEmail = String(email ?? '').trim().toLowerCase();
    this.ipLimiter.check(ip);
    this.emailLimiter.check(cleanEmail);
    const user = cleanEmail ? this.byEmail(cleanEmail) : null;
    const ok = user ? await verifyPassword(String(password ?? ''), user.password_hash) : await dummyVerify(String(password ?? ''));
    if (!ok || !user.active) {
      this.ipLimiter.hit(ip);
      this.emailLimiter.hit(cleanEmail);
      if (ok && !user.active) throw unauthorized('Dieses Konto ist deaktiviert.');
      throw unauthorized('E-Mail-Adresse oder Passwort ist falsch.');
    }
    this.emailLimiter.reset(cleanEmail);
    this.db.run('UPDATE users SET last_login_at = ? WHERE id = ?', [this.ctx.clock.now(), user.id]);
    return this.byId(user.id);
  }

  updateProfile(user, input) {
    const name = input.name !== undefined ? reqString(input.name, 'Name', { max: 100 }) : user.name;
    const notifyEmail = input.notifyEmail !== undefined ? toBool(input.notifyEmail) : Boolean(user.notify_email);
    let reminder = user.reminder_minutes;
    if (input.reminderMinutes !== undefined) {
      reminder = toInt(input.reminderMinutes, 'Erinnerung', { min: 0, max: 1440 });
      if (!REMINDER_CHOICES.includes(reminder)) throw badRequest('Ungültige Erinnerungszeit.');
    }
    this.db.run('UPDATE users SET name = ?, notify_email = ?, reminder_minutes = ? WHERE id = ?', [name, notifyEmail, reminder, user.id]);
    return this.byId(user.id);
  }

  async changePassword(user, { currentPassword, newPassword }, keepToken) {
    if (!(await verifyPassword(String(currentPassword ?? ''), user.password_hash))) {
      throw badRequest('Das aktuelle Passwort ist falsch.');
    }
    checkPassword(newPassword);
    this.db.run('UPDATE users SET password_hash = ? WHERE id = ?', [await hashPassword(newPassword), user.id]);
    this.ctx.sessions.destroyAllForUser(user.id, keepToken);
    this.ctx.audit(user.id, 'user.password', 'Passwort geändert');
  }

  regenerateCalendarToken(user) {
    this.db.run('UPDATE users SET calendar_token = ? WHERE id = ?', [randomToken(24), user.id]);
    return this.byId(user.id);
  }

  list() {
    return this.db.all('SELECT * FROM users ORDER BY active DESC, name COLLATE NOCASE').map(publicUser);
  }

  directory() {
    return this.db.all('SELECT id, name, email FROM users WHERE active = 1 ORDER BY name COLLATE NOCASE');
  }

  adminCount(excludeId = 0) {
    return this.db.get(`SELECT COUNT(*) AS n FROM users WHERE role = 'admin' AND active = 1 AND id <> ?`, [excludeId]).n;
  }

  adminUpdate(actor, id, input) {
    const target = this.byId(toId(id));
    if (!target) throw notFound('Benutzer nicht gefunden.');
    const name = input.name !== undefined ? reqString(input.name, 'Name', { max: 100 }) : target.name;
    const role = input.role !== undefined ? (input.role === 'admin' ? 'admin' : 'user') : target.role;
    const active = input.active !== undefined ? toBool(input.active) : Boolean(target.active);
    const losesAdmin = target.role === 'admin' && target.active && (role !== 'admin' || !active);
    if (losesAdmin && this.adminCount(target.id) === 0) {
      throw badRequest('Es muss mindestens eine aktive Administratorin bzw. ein aktiver Administrator bleiben.');
    }
    let cancelled = 0;
    this.db.tx(() => {
      this.db.run('UPDATE users SET name = ?, role = ?, active = ? WHERE id = ?', [name, role, active, target.id]);
      if (target.active && !active) {
        this.ctx.sessions.destroyAllForUser(target.id);
        cancelled = this.ctx.bookings.cancelFutureOfUser(actor, target.id, 'Konto wurde deaktiviert');
        this.ctx.audit(actor.id, 'user.deactivate', `${target.email} (${cancelled} zukünftige Buchungen storniert)`);
      } else if (!target.active && active) {
        this.ctx.audit(actor.id, 'user.activate', target.email);
      }
      if (role !== target.role) this.ctx.audit(actor.id, 'user.role', `${target.email}: ${role}`);
    });
    return { user: publicUser(this.byId(target.id)), cancelledBookings: cancelled };
  }

  async adminResetPassword(actor, id, newPassword) {
    const target = this.byId(toId(id));
    if (!target) throw notFound('Benutzer nicht gefunden.');
    checkPassword(newPassword);
    this.db.run('UPDATE users SET password_hash = ? WHERE id = ?', [await hashPassword(newPassword), target.id]);
    this.ctx.sessions.destroyAllForUser(target.id);
    this.ctx.audit(actor.id, 'user.password-reset', target.email);
  }
}
