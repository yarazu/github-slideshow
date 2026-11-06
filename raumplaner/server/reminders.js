import { BOOKING_SELECT } from './bookings.js';

const LOOKAHEAD_MS = 24 * 60 * 60000 + 60000;

/**
 * Erinnerungen vor Terminbeginn (Zeitpunkt pro Person einstellbar).
 * - Jede Person wird pro Termin genau einmal erinnert (gespeichert in reminders_sent),
 *   auch wenn der Server zwischendurch neu startet.
 * - War der Server zum Erinnerungszeitpunkt aus, wird beim Start nachgeholt – sofern
 *   der Termin noch nicht begonnen hat.
 * - Wird ein Termin zeitlich verschoben, wird neu erinnert.
 */
export class ReminderService {
  constructor(ctx) {
    this.ctx = ctx;
    this.timer = null;
  }

  start() {
    this.timer = setInterval(() => this.safeTick(), 30000);
    this.timer.unref?.();
    this.safeTick();
  }

  stop() {
    clearInterval(this.timer);
    this.timer = null;
  }

  safeTick() {
    try {
      return this.tick();
    } catch (err) {
      this.ctx.log.error('[erinnerung] Fehler:', err);
      return 0;
    }
  }

  tick() {
    const { db, bookings, notifier, clock } = this.ctx;
    const now = clock.now();
    const rows = db.all(
      `${BOOKING_SELECT} WHERE b.status = 'confirmed' AND b.type = 'booking' AND b.start_ts > ? AND b.start_ts <= ? ORDER BY b.start_ts`,
      [now, now + LOOKAHEAD_MS],
    );
    if (!rows.length) return 0;
    bookings.withAttendees(rows);

    let sent = 0;
    for (const b of rows) {
      const recipients = new Map();
      if (b.user_active) {
        recipients.set(b.user_id, {
          id: b.user_id,
          name: b.user_name,
          email: b.user_email,
          notify_email: b.user_notify_email,
          reminder_minutes: b.user_reminder_minutes,
        });
      }
      for (const a of b.attendees) {
        if (a.user_id && !recipients.has(a.user_id)) {
          recipients.set(a.user_id, {
            id: a.user_id,
            name: a.name,
            email: a.email,
            notify_email: a.notify_email,
            reminder_minutes: a.reminder_minutes,
          });
        }
      }

      for (const user of recipients.values()) {
        if (!user.reminder_minutes) continue;
        const remindAt = b.start_ts - user.reminder_minutes * 60000;
        if (remindAt > now) continue; // noch nicht fällig
        if (remindAt < b.time_changed_at) continue; // Termin wurde erst nach dem Erinnerungszeitpunkt gebucht/verschoben
        if (db.get('SELECT 1 AS x FROM reminders_sent WHERE booking_id = ? AND user_id = ?', [b.id, user.id])) continue;
        db.tx(() => {
          const r = db.run('INSERT OR IGNORE INTO reminders_sent (booking_id, user_id, sent_at) VALUES (?, ?, ?)', [b.id, user.id, now]);
          if (!r.changes) return;
          notifier.onReminder(b, user);
          sent += 1;
        });
      }
    }
    return sent;
  }
}
