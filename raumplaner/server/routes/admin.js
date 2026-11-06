import fs from 'node:fs';
import express from 'express';
import { publicUser } from '../auth.js';
import { notFound } from '../errors.js';
import { loadDemo } from '../demo.js';
import { renderEmail } from '../notifier.js';
import { reqEmail, toBool, toId, toInt } from '../validate.js';

export function adminRoutes(ctx) {
  const r = express.Router();
  const { db, users, settings, mailer, backups, hub, config } = ctx;

  r.get('/users', (req, res) => res.json(users.list()));

  r.post('/users', async (req, res) => {
    const body = req.body || {};
    const user = await users.create({ name: body.name, email: body.email, password: body.password, role: body.role });
    ctx.audit(req.user.id, 'user.create', `${user.email} (${user.role})`);
    res.status(201).json(publicUser(user));
  });

  r.put('/users/:id', (req, res) => res.json(users.adminUpdate(req.user, req.params.id, req.body || {})));

  r.post('/users/:id/password', async (req, res) => {
    await users.adminResetPassword(req.user, req.params.id, (req.body || {}).password);
    res.json({ ok: true });
  });

  r.get('/settings', (req, res) => res.json(settings.all()));

  r.put('/settings', (req, res) => {
    const next = settings.update(req.body || {});
    ctx.audit(req.user.id, 'settings.update', Object.keys(req.body || {}).join(', '));
    hub.broadcast('config-changed', {});
    res.json(next);
  });

  r.get('/system', (req, res) => {
    const outbox = db
      .all(
        `SELECT id, to_email, subject, status, attempts, last_error, next_attempt_at, created_at, sent_at
         FROM email_outbox ORDER BY CASE status WHEN 'failed' THEN 0 WHEN 'pending' THEN 1 ELSE 2 END, id DESC LIMIT 40`,
      )
      .map((m) => ({
        id: m.id,
        to: m.to_email,
        subject: m.subject,
        status: m.status,
        attempts: m.attempts,
        lastError: m.last_error,
        nextAttemptAt: m.next_attempt_at,
        createdAt: m.created_at,
        sentAt: m.sent_at,
      }));
    let dbSize = 0;
    try {
      dbSize = fs.statSync(ctx.dbFile).size;
    } catch {
      /* In-Memory-Datenbank */
    }
    const count = (sql, params) => db.get(sql, params).n;
    const now = ctx.clock.now();
    res.json({
      version: config.version,
      startedAt: ctx.startedAt,
      timezone: config.timezone,
      publicUrl: config.publicUrl,
      dbSize,
      liveConnections: hub.connectionCount,
      mail: mailer.status(),
      outbox,
      backups: backups.list(),
      backupDir: backups.dir,
      backupIntervalHours: config.backupIntervalHours,
      counts: {
        users: count('SELECT COUNT(*) AS n FROM users WHERE active = 1'),
        rooms: count(`SELECT COUNT(*) AS n FROM rooms WHERE kind <> 'area'`),
        upcomingBookings: count(`SELECT COUNT(*) AS n FROM bookings WHERE status = 'confirmed' AND end_ts > ?`, [now]),
        activeWatches: count('SELECT COUNT(*) AS n FROM room_watches WHERE end_ts > ?', [now]),
      },
    });
  });

  r.post('/mail/test', (req, res) => {
    const to = reqEmail((req.body || {}).to || req.user.email);
    if (!mailer.enabled) {
      return res.status(400).json({ error: 'mail_disabled', message: 'Der E-Mail-Versand ist nicht eingerichtet (SMTP_HOST fehlt).' });
    }
    const { text, html } = renderEmail({
      orgName: settings.get('org_name'),
      heading: 'Test-E-Mail vom Raumplaner',
      lines: ['Wenn diese Nachricht ankommt, ist der E-Mail-Versand korrekt eingerichtet.'],
      button: { label: 'Raumplaner öffnen', url: `${config.publicUrl}/#/` },
      footer: `Ausgelöst von ${req.user.name} in der Verwaltung.`,
    });
    const id = mailer.enqueue({ to, subject: 'Raumplaner: Test-E-Mail', text, html });
    ctx.audit(req.user.id, 'mail.test', to);
    res.json({ queued: true, id });
  });

  r.post('/mail/verify', async (req, res) => res.json(await mailer.verify()));

  r.post('/outbox/:id/retry', (req, res) => {
    if (!mailer.retry(toId(req.params.id))) throw notFound('E-Mail nicht gefunden oder bereits versendet.');
    res.json({ ok: true });
  });

  r.post('/backups', (req, res) => {
    const backup = backups.backupNow('manuell');
    ctx.audit(req.user.id, 'backup.create', backup.name);
    res.status(201).json(backup);
  });

  r.get('/audit', (req, res) => {
    const limit = toInt(req.query.limit, 'Limit', { min: 1, max: 500, def: 100 });
    res.json(
      db
        .all(
          `SELECT a.id, a.action, a.details, a.created_at, u.name AS user_name
           FROM audit_log a LEFT JOIN users u ON u.id = a.user_id ORDER BY a.id DESC LIMIT ?`,
          [limit],
        )
        .map((a) => ({ id: a.id, action: a.action, details: a.details, createdAt: a.created_at, userName: a.user_name })),
    );
  });

  r.post('/demo', (req, res) => {
    const withBookings = toBool((req.body || {}).withBookings, true);
    res.status(201).json(loadDemo(ctx, req.user, { withBookings }));
  });

  return r;
}
