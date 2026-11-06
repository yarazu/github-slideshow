import express from 'express';
import { publicUser, requireUser, SESSION_COOKIE, sessionCookieOptions } from '../auth.js';

export function authRoutes(ctx) {
  const r = express.Router();
  const { users, sessions, settings, config, mailer, notifier } = ctx;

  const startSession = (res, user) => {
    const token = sessions.create(user.id);
    res.cookie(SESSION_COOKIE, token, sessionCookieOptions(config));
  };

  const me = (user) => ({
    user: publicUser(user),
    calendarUrl: users.calendarUrl(user),
    unreadCount: notifier.unreadCount(user.id),
  });

  r.get('/config', (req, res) => {
    const s = settings.all();
    res.json({
      orgName: s.org_name,
      timezone: config.timezone,
      dayStartHour: s.day_start_hour,
      dayEndHour: s.day_end_hour,
      slotMinutes: s.slot_minutes,
      maxBookingMinutes: s.max_booking_minutes,
      maxDaysAhead: s.max_days_ahead,
      allowRegistration: Boolean(s.allow_registration),
      allowedEmailDomains: s.allowed_email_domains,
      equipmentOptions: s.equipment_options,
      defaultReminderMinutes: s.default_reminder_minutes,
      mailEnabled: mailer.enabled,
      needsSetup: users.count() === 0,
      version: config.version,
      loggedIn: Boolean(req.user),
    });
  });

  r.post('/setup', async (req, res) => {
    const user = await users.setup(req.body || {});
    startSession(res, user);
    res.status(201).json(me(user));
  });

  r.post('/auth/login', async (req, res) => {
    const user = await users.login(req.body || {}, req.ip);
    startSession(res, user);
    res.json(me(user));
  });

  r.post('/auth/register', async (req, res) => {
    const user = await users.register(req.body || {}, req.ip);
    startSession(res, user);
    res.status(201).json(me(user));
  });

  r.post('/auth/logout', (req, res) => {
    sessions.destroy(req.sessionToken);
    res.clearCookie(SESSION_COOKIE, { ...sessionCookieOptions(config), maxAge: undefined });
    res.json({ ok: true });
  });

  r.get('/me', requireUser, (req, res) => res.json(me(req.user)));

  r.put('/me', requireUser, (req, res) => {
    const user = users.updateProfile(req.user, req.body || {});
    res.json(me(user));
  });

  r.put('/me/password', requireUser, async (req, res) => {
    await users.changePassword(req.user, req.body || {}, req.sessionToken);
    res.json({ ok: true });
  });

  r.post('/me/calendar-token', requireUser, (req, res) => {
    const user = users.regenerateCalendarToken(req.user);
    res.json(me(user));
  });

  r.post('/me/test-notification', requireUser, (req, res) => {
    res.json(ctx.db.tx(() => notifier.onTest(req.user)));
  });

  r.get('/users/directory', requireUser, (req, res) => res.json(users.directory()));

  return r;
}
