import { BOOKING_SELECT } from '../bookings.js';
import { icsCalendar } from '../ics.js';

/**
 * Persönliches Kalender-Abo (iCal): Outlook, Google Kalender, Apple Kalender & Co.
 * holen sich darüber regelmäßig alle eigenen Termine. Der Link enthält ein geheimes Token
 * und kann im Profil jederzeit neu erzeugt werden.
 */
export function calendarFeed(ctx) {
  return (req, res) => {
    const token = String(req.params.file || '').replace(/\.ics$/i, '');
    const user = token && ctx.db.get('SELECT * FROM users WHERE calendar_token = ? AND active = 1', [token]);
    if (!user) {
      res.status(404).type('text/plain').send('Kalender nicht gefunden.');
      return;
    }
    const now = ctx.clock.now();
    const rows = ctx.bookings.withAttendees(
      ctx.db.all(
        `${BOOKING_SELECT}
         WHERE b.status = 'confirmed' AND b.type = 'booking' AND b.end_ts > ? AND b.start_ts < ?
           AND (b.user_id = ? OR EXISTS (SELECT 1 FROM booking_attendees ba WHERE ba.booking_id = b.id AND ba.email = ?))
         ORDER BY b.start_ts LIMIT 2000`,
        [now - 30 * 86400000, now + 400 * 86400000, user.id, user.email],
      ),
    );
    const ics = icsCalendar({
      method: 'PUBLISH',
      name: `Raumbuchungen – ${ctx.settings.get('org_name')}`,
      events: rows.map((b) => ctx.notifier.icsLines(b, 'CONFIRMED')),
    });
    res.setHeader('Content-Type', 'text/calendar; charset=utf-8');
    res.setHeader('Cache-Control', 'no-cache');
    res.send(ics);
  };
}
