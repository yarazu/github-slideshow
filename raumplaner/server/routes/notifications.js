import express from 'express';
import { requireUser } from '../auth.js';
import { toInt } from '../validate.js';

export function notificationRoutes(ctx) {
  const r = express.Router();
  const { db, hub, notifier } = ctx;

  const toApi = (n) => ({
    id: n.id,
    type: n.type,
    title: n.title,
    body: n.body,
    link: n.link,
    bookingId: n.booking_id,
    createdAt: n.created_at,
    read: n.read_at !== null,
  });

  r.get('/notifications', requireUser, (req, res) => {
    const limit = toInt(req.query.limit, 'Limit', { min: 1, max: 200, def: 50 });
    const before = req.query.before ? toInt(req.query.before, 'Before', { min: 1 }) : Number.MAX_SAFE_INTEGER;
    const items = db
      .all('SELECT * FROM notifications WHERE user_id = ? AND id < ? ORDER BY id DESC LIMIT ?', [req.user.id, before, limit])
      .map(toApi);
    res.json({ items, unreadCount: notifier.unreadCount(req.user.id) });
  });

  r.post('/notifications/read', requireUser, (req, res) => {
    const now = ctx.clock.now();
    const body = req.body || {};
    if (body.all) {
      db.run('UPDATE notifications SET read_at = ? WHERE user_id = ? AND read_at IS NULL', [now, req.user.id]);
    } else if (Array.isArray(body.ids)) {
      db.tx(() => {
        for (const id of body.ids.slice(0, 500)) {
          db.run('UPDATE notifications SET read_at = ? WHERE id = ? AND user_id = ? AND read_at IS NULL', [now, Number(id) || 0, req.user.id]);
        }
      });
    }
    const unreadCount = notifier.unreadCount(req.user.id);
    hub.sendToUser(req.user.id, 'unread', { unreadCount });
    res.json({ unreadCount });
  });

  // Live-Kanal (Server-Sent Events)
  r.get('/events', requireUser, (req, res) => {
    hub.attach(req, res, req.user.id, { unreadCount: notifier.unreadCount(req.user.id), serverTime: Date.now() });
  });

  return r;
}
