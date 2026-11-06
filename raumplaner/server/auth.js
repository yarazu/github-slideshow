import crypto from 'node:crypto';
import { promisify } from 'node:util';
import { HttpError, forbidden, tooMany, unauthorized } from './errors.js';

const scrypt = promisify(crypto.scrypt);
const SCRYPT = { N: 16384, r: 8, p: 1 };
const KEYLEN = 64;

export const SESSION_COOKIE = 'rp_session';

export async function hashPassword(plain) {
  const salt = crypto.randomBytes(16);
  const hash = await scrypt(plain.normalize('NFKC'), salt, KEYLEN, SCRYPT);
  return ['scrypt', SCRYPT.N, SCRYPT.r, SCRYPT.p, salt.toString('base64'), hash.toString('base64')].join('$');
}

export async function verifyPassword(plain, stored) {
  const [alg, n, r, p, saltB64, hashB64] = String(stored || '').split('$');
  if (alg !== 'scrypt' || !saltB64 || !hashB64) return false;
  const expected = Buffer.from(hashB64, 'base64');
  const actual = await scrypt(String(plain).normalize('NFKC'), Buffer.from(saltB64, 'base64'), expected.length, {
    N: Number(n),
    r: Number(r),
    p: Number(p),
  });
  return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
}

/** Ein Hash, der verglichen wird, wenn es den Benutzer gar nicht gibt (gleiche Laufzeit = kein Konten-Raten). */
let dummyHash = null;
export async function dummyVerify(plain) {
  if (!dummyHash) dummyHash = await hashPassword('dummy-password-for-timing');
  await verifyPassword(plain, dummyHash);
  return false;
}

export const randomToken = (bytes = 32) => crypto.randomBytes(bytes).toString('base64url');
const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');

export class Sessions {
  constructor({ db, config, clock }) {
    this.db = db;
    this.clock = clock;
    this.ttl = config.sessionDays * 86400000;
  }

  create(userId) {
    const token = randomToken();
    const now = this.clock.now();
    this.db.run('INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)', [
      sha256(token),
      userId,
      now,
      now + this.ttl,
    ]);
    return token;
  }

  /** Liefert den angemeldeten (aktiven) Benutzer oder null. Verlängert Sitzungen gleitend. */
  lookup(token) {
    if (!token) return null;
    const now = this.clock.now();
    const hash = sha256(token);
    const row = this.db.get(
      `SELECT s.expires_at, u.* FROM sessions s JOIN users u ON u.id = s.user_id
       WHERE s.token_hash = ? AND s.expires_at > ? AND u.active = 1`,
      [hash, now],
    );
    if (!row) return null;
    if (row.expires_at - now < this.ttl / 2) {
      this.db.run('UPDATE sessions SET expires_at = ? WHERE token_hash = ?', [now + this.ttl, hash]);
    }
    delete row.expires_at;
    return row;
  }

  destroy(token) {
    if (token) this.db.run('DELETE FROM sessions WHERE token_hash = ?', [sha256(token)]);
  }

  destroyAllForUser(userId, exceptToken) {
    if (exceptToken) {
      this.db.run('DELETE FROM sessions WHERE user_id = ? AND token_hash <> ?', [userId, sha256(exceptToken)]);
    } else {
      this.db.run('DELETE FROM sessions WHERE user_id = ?', [userId]);
    }
  }

  purgeExpired() {
    return this.db.run('DELETE FROM sessions WHERE expires_at <= ?', [this.clock.now()]).changes;
  }
}

export function parseCookies(header) {
  const out = {};
  if (!header) return out;
  for (const part of header.split(';')) {
    const idx = part.indexOf('=');
    if (idx < 0) continue;
    const key = part.slice(0, idx).trim();
    const value = part.slice(idx + 1).trim();
    try {
      out[key] = decodeURIComponent(value);
    } catch {
      out[key] = value;
    }
  }
  return out;
}

export function sessionCookieOptions(config) {
  return {
    httpOnly: true,
    sameSite: 'lax',
    secure: config.cookieSecure,
    path: '/',
    maxAge: config.sessionDays * 86400000,
  };
}

export function loadUser(ctx) {
  return (req, _res, next) => {
    const token = parseCookies(req.headers.cookie)[SESSION_COOKIE];
    req.sessionToken = token || null;
    req.user = token ? ctx.sessions.lookup(token) : null;
    next();
  };
}

export function requireUser(req, _res, next) {
  next(req.user ? undefined : unauthorized());
}

export function requireAdmin(req, _res, next) {
  if (!req.user) return next(unauthorized());
  next(req.user.role === 'admin' ? undefined : forbidden('Nur für Administratoren.'));
}

/**
 * CSRF-Schutz: Zustandsändernde API-Aufrufe müssen einen eigenen Header mitsenden.
 * Fremde Webseiten können diesen Header nicht setzen, ohne dass der Browser vorher
 * nachfragt (CORS-Preflight) – und diese Nachfrage beantwortet der Server nicht.
 */
export function csrfGuard(req, _res, next) {
  if (req.method === 'GET' || req.method === 'HEAD' || req.method === 'OPTIONS') return next();
  if (req.get('x-requested-with') === 'raumplaner') return next();
  next(new HttpError(403, 'csrf', 'Ungültige Anfrage (CSRF-Schutz). Bitte lade die Seite neu.'));
}

/** Einfache Begrenzung von Anmeldeversuchen (pro IP und pro E-Mail-Adresse). */
export class RateLimiter {
  constructor({ limit, windowMs, clock }) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.clock = clock;
    this.hits = new Map();
  }

  check(key) {
    const now = this.clock.now();
    const entry = this.hits.get(key);
    if (entry && entry.resetAt > now && entry.count >= this.limit) {
      const minutes = Math.ceil((entry.resetAt - now) / 60000);
      throw tooMany(`Zu viele Versuche. Bitte warte ${minutes} Minute(n) und versuche es erneut.`);
    }
  }

  hit(key) {
    const now = this.clock.now();
    const entry = this.hits.get(key);
    if (!entry || entry.resetAt <= now) this.hits.set(key, { count: 1, resetAt: now + this.windowMs });
    else entry.count += 1;
    if (this.hits.size > 10000) {
      for (const [k, v] of this.hits) if (v.resetAt <= now) this.hits.delete(k);
    }
  }

  reset(key) {
    this.hits.delete(key);
  }
}

/** Benutzer-Objekt für die API (ohne Passwort-Hash). */
export function publicUser(u) {
  if (!u) return null;
  return {
    id: u.id,
    email: u.email,
    name: u.name,
    role: u.role,
    active: Boolean(u.active),
    notifyEmail: Boolean(u.notify_email),
    reminderMinutes: u.reminder_minutes,
    createdAt: u.created_at,
    lastLoginAt: u.last_login_at ?? null,
  };
}
