import nodemailer from 'nodemailer';

/** Wartezeiten zwischen Zustellversuchen (Minuten). Danach gilt eine E-Mail als fehlgeschlagen. */
export const RETRY_MINUTES = [1, 2, 5, 15, 30, 60, 180, 360];
export const MAX_ATTEMPTS = RETRY_MINUTES.length + 1;

/**
 * E-Mail-Versand nach dem Outbox-Prinzip:
 * E-Mails werden in derselben Datenbank-Transaktion gespeichert wie die Buchung selbst.
 * Ein Hintergrundprozess stellt sie zu und versucht es bei Fehlern (z. B. Mailserver kurz
 * nicht erreichbar, Neustart) automatisch erneut. Dadurch geht keine Benachrichtigung verloren.
 */
export class Mailer {
  constructor({ db, config, log, clock, transport }) {
    this.db = db;
    this.log = log;
    this.clock = clock;
    this.from = config.smtp.from;
    this.timer = null;
    this.kickTimer = null;
    this.processing = false;
    this.lastError = null;

    if (transport) {
      this.transport = transport;
      this.mode = 'custom';
    } else if (config.mailLogOnly) {
      this.transport = nodemailer.createTransport({ jsonTransport: true });
      this.mode = 'log';
    } else if (config.smtp.host) {
      this.transport = nodemailer.createTransport({
        host: config.smtp.host,
        port: config.smtp.port,
        secure: config.smtp.secure,
        auth: config.smtp.user ? { user: config.smtp.user, pass: config.smtp.pass } : undefined,
        tls: { rejectUnauthorized: config.smtp.rejectUnauthorized },
        connectionTimeout: 20000,
        greetingTimeout: 20000,
        socketTimeout: 60000,
      });
      this.mode = 'smtp';
      this.smtpLabel = `${config.smtp.host}:${config.smtp.port}`;
    } else {
      this.transport = null;
      this.mode = 'disabled';
    }
  }

  get enabled() {
    return Boolean(this.transport);
  }

  /** Legt eine E-Mail in die Outbox. Muss nicht in einer Transaktion laufen, darf es aber. */
  enqueue({ to, subject, text, html, ics, icsMethod, attachments }) {
    if (!this.enabled || !to) return null;
    const now = this.clock.now();
    const r = this.db.run(
      `INSERT INTO email_outbox (to_email, subject, text_body, html_body, ics, ics_method, attachments, next_attempt_at, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [to, subject, text, html || null, ics || null, icsMethod || null, attachments ? JSON.stringify(attachments) : null, now, now],
    );
    this.db.afterCommit(() => this.kick());
    return r.lastInsertRowid;
  }

  /** Stößt die Zustellung zeitnah an (gebündelt). */
  kick() {
    if (!this.enabled || this.kickTimer) return;
    this.kickTimer = setTimeout(() => {
      this.kickTimer = null;
      this.processQueue().catch((err) => this.log.error('[mail] Fehler in der Warteschlange:', err));
    }, 50);
    this.kickTimer.unref?.();
  }

  async processQueue() {
    if (!this.enabled || this.processing) return 0;
    this.processing = true;
    let delivered = 0;
    try {
      for (;;) {
        const batch = this.db.all(
          `SELECT * FROM email_outbox WHERE status = 'pending' AND next_attempt_at <= ? ORDER BY id LIMIT 20`,
          [this.clock.now()],
        );
        if (!batch.length) break;
        for (const mail of batch) {
          if (await this.deliver(mail)) delivered += 1;
        }
        if (batch.length < 20) break;
      }
    } finally {
      this.processing = false;
    }
    return delivered;
  }

  async deliver(mail) {
    const message = {
      from: this.from,
      to: mail.to_email,
      subject: mail.subject,
      text: mail.text_body,
      html: mail.html_body || undefined,
    };
    if (mail.ics) {
      message.icalEvent = { method: mail.ics_method || 'REQUEST', filename: 'termin.ics', content: mail.ics };
    }
    if (mail.attachments) {
      message.attachments = JSON.parse(mail.attachments);
    }
    try {
      await this.transport.sendMail(message);
      this.db.run(`UPDATE email_outbox SET status = 'sent', attempts = attempts + 1, sent_at = ?, last_error = NULL WHERE id = ?`, [
        this.clock.now(),
        mail.id,
      ]);
      if (this.mode === 'log') {
        this.log.info(`[mail] (nur Protokoll) an ${mail.to_email}: ${mail.subject}\n${indent(mail.text_body)}`);
      }
      this.lastError = null;
      return true;
    } catch (err) {
      const attempts = mail.attempts + 1;
      const message = String(err?.message || err).slice(0, 500);
      this.lastError = { at: this.clock.now(), message };
      if (attempts >= MAX_ATTEMPTS) {
        this.db.run(`UPDATE email_outbox SET status = 'failed', attempts = ?, last_error = ? WHERE id = ?`, [attempts, message, mail.id]);
        this.log.error(`[mail] Endgültig fehlgeschlagen an ${mail.to_email} (${mail.subject}): ${message}`);
      } else {
        const wait = RETRY_MINUTES[attempts - 1] * 60000;
        this.db.run(`UPDATE email_outbox SET attempts = ?, last_error = ?, next_attempt_at = ? WHERE id = ?`, [
          attempts,
          message,
          this.clock.now() + wait,
          mail.id,
        ]);
        this.log.warn(`[mail] Versuch ${attempts} an ${mail.to_email} fehlgeschlagen, neuer Versuch in ${wait / 60000} Min.: ${message}`);
      }
      return false;
    }
  }

  start() {
    if (!this.enabled) return;
    this.timer = setInterval(() => {
      this.processQueue().catch((err) => this.log.error('[mail] Fehler in der Warteschlange:', err));
    }, 15000);
    this.timer.unref?.();
    this.kick();
  }

  stop() {
    clearInterval(this.timer);
    clearTimeout(this.kickTimer);
    this.timer = null;
    this.kickTimer = null;
  }

  /** Prüft die Verbindung zum Mailserver (nur SMTP). */
  async verify() {
    if (this.mode !== 'smtp') return { ok: this.enabled, mode: this.mode };
    try {
      await this.transport.verify();
      return { ok: true, mode: this.mode };
    } catch (err) {
      return { ok: false, mode: this.mode, error: String(err?.message || err) };
    }
  }

  retry(id) {
    const r = this.db.run(
      `UPDATE email_outbox SET status = 'pending', next_attempt_at = ?, attempts = 0 WHERE id = ? AND status <> 'sent'`,
      [this.clock.now(), id],
    );
    this.kick();
    return r.changes > 0;
  }

  stats() {
    const counts = { pending: 0, sent: 0, failed: 0 };
    for (const row of this.db.all('SELECT status, COUNT(*) AS n FROM email_outbox GROUP BY status')) counts[row.status] = row.n;
    return counts;
  }

  status() {
    return {
      mode: this.mode,
      enabled: this.enabled,
      server: this.smtpLabel || null,
      from: this.from,
      lastError: this.lastError,
      counts: this.stats(),
    };
  }
}

function indent(text) {
  return String(text)
    .split('\n')
    .map((l) => `    ${l}`)
    .join('\n');
}
