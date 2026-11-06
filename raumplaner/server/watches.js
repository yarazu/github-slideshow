import { formatRange } from '../public/shared/time.js';
import { badRequest } from './errors.js';
import { toId, toTimestamp } from './validate.js';

const MAX_ACTIVE_WATCHES = 20;

/**
 * „Benachrichtige mich, wenn der Raum frei wird“:
 * Ist ein Wunschraum belegt, kann man sich vormerken. Sobald der Zeitraum durch eine
 * Stornierung, Änderung oder vorzeitiges Beenden komplett frei wird, kommt eine Nachricht.
 */
export class WatchService {
  constructor(ctx) {
    this.ctx = ctx;
  }

  get db() {
    return this.ctx.db;
  }

  toApi(w) {
    return {
      id: w.id,
      roomId: w.room_id,
      roomName: w.room_name,
      floorName: w.floor_name,
      buildingName: w.building_name,
      start: w.start_ts,
      end: w.end_ts,
      createdAt: w.created_at,
    };
  }

  load(id) {
    return this.db.get(
      `SELECT w.*, r.name AS room_name, f.name AS floor_name, bl.name AS building_name
       FROM room_watches w JOIN rooms r ON r.id = w.room_id JOIN floors f ON f.id = r.floor_id JOIN buildings bl ON bl.id = f.building_id
       WHERE w.id = ?`,
      [id],
    );
  }

  create(user, input) {
    const room = this.ctx.bookings.bookableRoom(toId(input.roomId, 'Raum'));
    const start = toTimestamp(input.start, 'Beginn');
    const end = toTimestamp(input.end, 'Ende');
    const now = this.ctx.clock.now();
    if (!(end > start)) throw badRequest('Das Ende muss nach dem Beginn liegen.');
    if (end <= now) throw badRequest('Der Zeitraum liegt in der Vergangenheit.');
    if (!this.ctx.bookings.conflicts(room.id, Math.max(start, now), end).length) return { free: true };

    const existing = this.db.get('SELECT id FROM room_watches WHERE user_id = ? AND room_id = ? AND start_ts = ? AND end_ts = ?', [
      user.id,
      room.id,
      start,
      end,
    ]);
    if (existing) return { free: false, watch: this.toApi(this.load(existing.id)) };

    const active = this.db.get('SELECT COUNT(*) AS n FROM room_watches WHERE user_id = ? AND end_ts > ?', [user.id, now]).n;
    if (active >= MAX_ACTIVE_WATCHES) {
      throw badRequest(`Du hast bereits ${MAX_ACTIVE_WATCHES} aktive Raum-Wünsche. Bitte entferne zuerst ältere.`);
    }
    const r = this.db.run('INSERT INTO room_watches (user_id, room_id, start_ts, end_ts, created_at) VALUES (?, ?, ?, ?, ?)', [
      user.id,
      room.id,
      start,
      end,
      now,
    ]);
    this.ctx.audit(user.id, 'watch.create', `${room.name}: ${formatRange(start, end, this.ctx.config.timezone)}`);
    return { free: false, watch: this.toApi(this.load(r.lastInsertRowid)) };
  }

  list(user) {
    return this.db
      .all(
        `SELECT w.*, r.name AS room_name, f.name AS floor_name, bl.name AS building_name
         FROM room_watches w JOIN rooms r ON r.id = w.room_id JOIN floors f ON f.id = r.floor_id JOIN buildings bl ON bl.id = f.building_id
         WHERE w.user_id = ? AND w.end_ts > ? ORDER BY w.start_ts`,
        [user.id, this.ctx.clock.now()],
      )
      .map((w) => this.toApi(w));
  }

  remove(user, id) {
    return this.db.run('DELETE FROM room_watches WHERE id = ? AND user_id = ?', [toId(id), user.id]).changes > 0;
  }

  /** Prüft nach einer Freigabe, ob vorgemerkte Wünsche jetzt erfüllbar sind. Gibt die Anzahl Benachrichtigungen zurück. */
  checkFreed(roomId, from, to) {
    const now = this.ctx.clock.now();
    const watches = this.db.all(
      `SELECT w.*, u.name AS user_name, u.email AS user_email, u.notify_email, u.active
       FROM room_watches w JOIN users u ON u.id = w.user_id
       WHERE w.room_id = ? AND w.start_ts < ? AND w.end_ts > ? AND w.end_ts > ?`,
      [roomId, to, from, now],
    );
    if (!watches.length) return 0;
    const room = this.db.get(
      `SELECT r.*, f.name AS floor_name, bl.name AS building_name
       FROM rooms r JOIN floors f ON f.id = r.floor_id JOIN buildings bl ON bl.id = f.building_id WHERE r.id = ?`,
      [roomId],
    );
    if (!room) return 0;
    let notified = 0;
    for (const w of watches) {
      if (!w.active) continue;
      if (this.ctx.bookings.conflicts(roomId, Math.max(w.start_ts, now), w.end_ts).length) continue;
      this.db.tx(() => {
        const r = this.db.run('DELETE FROM room_watches WHERE id = ?', [w.id]);
        if (!r.changes) return;
        this.ctx.notifier.onWatchFree(w, room, { id: w.user_id, name: w.user_name, email: w.user_email, notify_email: w.notify_email });
        notified += 1;
      });
    }
    return notified;
  }

  purgeExpired() {
    return this.db.run('DELETE FROM room_watches WHERE end_ts <= ?', [this.ctx.clock.now()]).changes;
  }
}
