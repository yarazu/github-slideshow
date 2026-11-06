import { randomUUID } from 'node:crypto';
import { expandRecurrence, formatDuration, formatRange, parseDateKey } from '../public/shared/time.js';
import { badRequest, conflict, forbidden, isBookingConflictError, notFound } from './errors.js';
import { isEmail, optString, reqString, toBool, toId, toTimestamp } from './validate.js';

export const BOOKING_SELECT = `
  SELECT b.*, r.name AS room_name, r.kind AS room_kind, r.capacity AS room_capacity, r.floor_id,
         f.name AS floor_name, f.building_id, bl.name AS building_name,
         u.name AS user_name, u.email AS user_email, u.active AS user_active,
         u.notify_email AS user_notify_email, u.reminder_minutes AS user_reminder_minutes
  FROM bookings b
  JOIN rooms r ON r.id = b.room_id
  JOIN floors f ON f.id = r.floor_id
  JOIN buildings bl ON bl.id = f.building_id
  JOIN users u ON u.id = b.user_id`;

const ROOM_SELECT = `
  SELECT r.*, f.name AS floor_name, f.building_id, bl.name AS building_name
  FROM rooms r JOIN floors f ON f.id = r.floor_id JOIN buildings bl ON bl.id = f.building_id`;

/**
 * Buchungslogik. Wichtigste Garantie: Ein Raum kann zu keinem Zeitpunkt doppelt belegt sein.
 * Die Prüfung erfolgt (1) hier in der Anwendung mit verständlicher Fehlermeldung und
 * (2) zusätzlich durch einen Datenbank-Trigger innerhalb derselben Transaktion.
 */
export class BookingService {
  constructor(ctx) {
    this.ctx = ctx;
  }

  get db() {
    return this.ctx.db;
  }

  get tz() {
    return this.ctx.config.timezone;
  }

  now() {
    return this.ctx.clock.now();
  }

  // ------------------------------------------------------------------ Lesen

  withAttendees(rows) {
    if (!rows.length) return rows;
    const byId = new Map(rows.map((r) => [r.id, []]));
    const ids = [...byId.keys()];
    for (let i = 0; i < ids.length; i += 500) {
      const chunk = ids.slice(i, i + 500);
      const att = this.db.all(
        `SELECT ba.booking_id, ba.email, u.id AS user_id, u.name, u.notify_email, u.reminder_minutes
         FROM booking_attendees ba LEFT JOIN users u ON u.email = ba.email AND u.active = 1
         WHERE ba.booking_id IN (${chunk.map(() => '?').join(',')}) ORDER BY ba.email`,
        chunk,
      );
      for (const a of att) byId.get(a.booking_id).push(a);
    }
    for (const r of rows) r.attendees = byId.get(r.id);
    return rows;
  }

  loadFull(id) {
    const row = this.db.get(`${BOOKING_SELECT} WHERE b.id = ?`, [id]);
    return row ? this.withAttendees([row])[0] : null;
  }

  conflicts(roomId, start, end, excludeId = 0) {
    return this.db.all(
      `${BOOKING_SELECT} WHERE b.room_id = ? AND b.status = 'confirmed' AND b.start_ts < ? AND b.end_ts > ? AND b.id <> ? ORDER BY b.start_ts`,
      [roomId, end, start, excludeId],
    );
  }

  canSeeDetails(row, viewer) {
    if (!row.is_private) return true;
    if (!viewer) return false;
    if (viewer.role === 'admin' || viewer.id === row.user_id) return true;
    const email = String(viewer.email).toLowerCase();
    return (row.attendees || []).some((a) => a.email.toLowerCase() === email);
  }

  toApi(row, viewer) {
    const visible = this.canSeeDetails(row, viewer);
    return {
      id: row.id,
      type: row.type,
      title: visible ? row.title : 'Privater Termin',
      description: visible ? row.description : '',
      isPrivate: Boolean(row.is_private),
      masked: !visible,
      start: row.start_ts,
      end: row.end_ts,
      status: row.status,
      seriesId: row.series_id,
      cancelReason: row.cancel_reason,
      room: { id: row.room_id, name: row.room_name, kind: row.room_kind, capacity: row.room_capacity },
      floor: { id: row.floor_id, name: row.floor_name },
      building: { id: row.building_id, name: row.building_name },
      user: { id: row.user_id, name: row.user_name, email: row.user_email },
      attendees: visible ? (row.attendees || []).map((a) => ({ email: a.email, name: a.name || null })) : [],
      isOwner: viewer?.id === row.user_id,
      canEdit: Boolean(
        viewer && (viewer.role === 'admin' || viewer.id === row.user_id) && row.status === 'confirmed' && row.end_ts > this.now(),
      ),
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  }

  list({ from, to, roomId, floorId, buildingId }, viewer) {
    if (!(to > from)) throw badRequest('Ungültiger Zeitraum.');
    if (to - from > 62 * 86400000) throw badRequest('Der Zeitraum ist zu groß (max. 62 Tage).');
    const where = [`b.status = 'confirmed'`, 'b.start_ts < ?', 'b.end_ts > ?'];
    const params = [to, from];
    if (roomId) {
      where.push('b.room_id = ?');
      params.push(roomId);
    }
    if (floorId) {
      where.push('r.floor_id = ?');
      params.push(floorId);
    }
    if (buildingId) {
      where.push('f.building_id = ?');
      params.push(buildingId);
    }
    const rows = this.db.all(`${BOOKING_SELECT} WHERE ${where.join(' AND ')} ORDER BY b.start_ts`, params);
    return this.withAttendees(rows).map((r) => this.toApi(r, viewer));
  }

  /** Eigene Termine: als buchende Person oder als Teilnehmer/in. */
  mine(user, { scope = 'upcoming', limit = 200 } = {}) {
    const past = scope === 'past';
    const rows = this.db.all(
      `${BOOKING_SELECT}
       WHERE b.status = 'confirmed' AND b.type = 'booking' AND ${past ? 'b.end_ts <= ?' : 'b.end_ts > ?'}
         AND (b.user_id = ? OR EXISTS (SELECT 1 FROM booking_attendees ba WHERE ba.booking_id = b.id AND ba.email = ?))
       ORDER BY b.start_ts ${past ? 'DESC' : 'ASC'} LIMIT ?`,
      [this.now(), user.id, user.email, limit],
    );
    return this.withAttendees(rows).map((r) => this.toApi(r, user));
  }

  get(id, viewer) {
    const row = this.loadFull(id);
    if (!row) throw notFound('Buchung nicht gefunden.');
    return this.toApi(row, viewer);
  }

  /** Belegung aller Räume in einem Zeitraum: { busy: { [roomId]: [buchungen] } }. Fehlt ein Raum, ist er frei. */
  availability({ start, end, excludeId = 0 }, viewer) {
    if (!(end > start)) throw badRequest('Das Ende muss nach dem Beginn liegen.');
    if (end - start > 31 * 86400000) throw badRequest('Der Zeitraum ist zu groß.');
    const rows = this.withAttendees(
      this.db.all(
        `${BOOKING_SELECT} WHERE b.status = 'confirmed' AND b.start_ts < ? AND b.end_ts > ? AND b.id <> ? ORDER BY b.start_ts`,
        [end, start, excludeId],
      ),
    );
    const busy = {};
    for (const r of rows) (busy[r.room_id] ||= []).push(this.toApi(r, viewer));
    return { start, end, busy };
  }

  // ------------------------------------------------------------------ Prüfungen

  bookableRoom(roomId) {
    const room = this.db.get(`${ROOM_SELECT} WHERE r.id = ?`, [roomId]);
    if (!room) throw notFound('Der Raum existiert nicht (mehr).');
    if (room.kind === 'area') throw badRequest('Dieser Bereich kann nicht gebucht werden.');
    return room;
  }

  assertCanModify(actor, row) {
    if (actor.role !== 'admin' && actor.id !== row.user_id) {
      throw forbidden('Nur die buchende Person oder die Administration kann diese Buchung ändern.');
    }
  }

  checkTimes(start, end, actor, { allowStartedAt = null } = {}) {
    const s = this.ctx.settings.all();
    const now = this.now();
    if (!(end > start)) throw badRequest('Das Ende muss nach dem Beginn liegen.');
    if (end - start < 5 * 60000) throw badRequest('Eine Buchung muss mindestens 5 Minuten dauern.');
    if (end <= now) throw badRequest('Der Zeitraum liegt in der Vergangenheit.');
    const grace = Math.max(5, s.slot_minutes) * 60000;
    if (start < now - grace && start !== allowStartedAt) throw badRequest('Der Beginn liegt in der Vergangenheit.');
    if (actor.role !== 'admin') {
      if (end - start > s.max_booking_minutes * 60000) {
        throw badRequest(`Eine Buchung darf höchstens ${formatDuration(s.max_booking_minutes * 60000)} dauern.`);
      }
      if (start > now + s.max_days_ahead * 86400000) {
        throw badRequest(`Buchungen sind höchstens ${s.max_days_ahead} Tage im Voraus möglich.`);
      }
    }
  }

  normalizeAttendees(list, bookerEmail) {
    if (list === undefined || list === null || list === '') return [];
    const items = Array.isArray(list) ? list : String(list).split(/[\n,;]+/);
    const seen = new Set([String(bookerEmail).toLowerCase()]);
    const out = [];
    for (const raw of items) {
      let value = String(raw ?? '').trim();
      const angle = /<([^>]+)>/.exec(value);
      if (angle) value = angle[1];
      value = value.trim().toLowerCase();
      if (!value) continue;
      if (!isEmail(value)) throw badRequest(`Ungültige E-Mail-Adresse bei den Teilnehmenden: ${value}`);
      if (seen.has(value)) continue;
      seen.add(value);
      out.push(value);
    }
    if (out.length > 50) throw badRequest('Maximal 50 Teilnehmende pro Buchung.');
    return out;
  }

  conflictPayload(occurrences, viewer) {
    return occurrences.map((o) => ({
      start: o.start,
      end: o.end,
      bookings: this.withAttendees(o.conflicts).map((r) => this.toApi(r, viewer)),
    }));
  }

  // ------------------------------------------------------------------ Schreiben

  /**
   * Neue Buchung oder Sperrung (optional als Serie).
   * input: { roomId, title, description, start, end, attendees, isPrivate, type, recurrence: {freq, until}, skipConflicts }
   */
  create(actor, input) {
    const isAdmin = actor.role === 'admin';
    const type = input.type === 'block' ? 'block' : 'booking';
    if (type === 'block' && !isAdmin) throw forbidden('Nur die Administration kann Räume sperren.');
    const room = this.bookableRoom(toId(input.roomId, 'Raum'));
    if (!room.bookable && !isAdmin) throw badRequest('Dieser Raum ist derzeit nicht buchbar.');

    const title =
      type === 'block'
        ? optString(input.title, 'Grund', { max: 200 }) || 'Gesperrt'
        : reqString(input.title, 'Titel', { max: 200 });
    const description = optString(input.description, 'Beschreibung', { max: 4000 });
    const isPrivate = type === 'booking' && toBool(input.isPrivate);
    const start = toTimestamp(input.start, 'Beginn');
    const end = toTimestamp(input.end, 'Ende');
    this.checkTimes(start, end, actor);
    const attendees = type === 'booking' ? this.normalizeAttendees(input.attendees, actor.email) : [];

    let occurrences = [{ start, end }];
    const rule = input.recurrence && input.recurrence.freq && input.recurrence.freq !== 'none' ? input.recurrence : null;
    if (rule) {
      if (!parseDateKey(rule.until)) throw badRequest('Bitte ein gültiges Enddatum für die Serie angeben.');
      try {
        occurrences = expandRecurrence(start, end, rule, this.tz);
      } catch (err) {
        throw badRequest(err.message);
      }
      const maxDays = this.ctx.settings.get('max_days_ahead');
      const last = occurrences[occurrences.length - 1];
      if (!isAdmin && last.start > this.now() + maxDays * 86400000) {
        throw badRequest(`Serientermine dürfen höchstens ${maxDays} Tage in die Zukunft reichen.`);
      }
    }
    const skipConflicts = toBool(input.skipConflicts);
    const now = this.now();

    try {
      return this.db.tx(() => {
        const conflicting = [];
        const toCancel = new Map();
        for (const occ of occurrences) {
          const found = this.conflicts(room.id, occ.start, occ.end);
          if (!found.length) continue;
          if (type === 'block' && found.every((x) => x.type === 'booking')) {
            for (const x of found) toCancel.set(x.id, x);
          } else {
            conflicting.push({ ...occ, conflicts: found });
          }
        }

        let planned = occurrences;
        if (conflicting.length) {
          const canSkip = skipConflicts && occurrences.length > 1 && conflicting.length < occurrences.length;
          if (!canSkip) {
            throw conflict(
              occurrences.length > 1
                ? `${conflicting.length} von ${occurrences.length} Terminen sind bereits belegt.`
                : 'Der Raum ist in diesem Zeitraum bereits belegt.',
              { conflicts: this.conflictPayload(conflicting, actor), occurrences: occurrences.length },
            );
          }
          const blocked = new Set(conflicting.map((o) => o.start));
          planned = occurrences.filter((o) => !blocked.has(o.start));
        }

        if (toCancel.size) {
          this.cancelRows(actor, this.withAttendees([...toCancel.values()]), `Raum gesperrt – ${title}`);
        }

        const seriesId = planned.length > 1 ? randomUUID() : null;
        const ids = [];
        for (const occ of planned) {
          const r = this.db.run(
            `INSERT INTO bookings (room_id, user_id, type, title, description, is_private, start_ts, end_ts, series_id, time_changed_at, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
            [room.id, actor.id, type, title, description, isPrivate, occ.start, occ.end, seriesId, now, now, now],
          );
          ids.push(r.lastInsertRowid);
          for (const email of attendees) {
            this.db.run('INSERT INTO booking_attendees (booking_id, email) VALUES (?, ?)', [r.lastInsertRowid, email]);
          }
        }
        const created = ids.map((id) => this.loadFull(id));
        const first = created[0];
        this.ctx.audit(
          actor.id,
          type === 'block' ? 'block.create' : 'booking.create',
          `${room.name}: „${title}“ – ${created.length > 1 ? `${created.length} Termine ab ` : ''}${formatRange(first.start_ts, first.end_ts, this.tz)}`,
        );
        this.ctx.notifier.onCreated(created, actor);
        this.db.afterCommit(() => this.ctx.hub.broadcast('bookings-changed', { roomIds: [room.id] }));
        return {
          bookings: created.map((r) => this.toApi(r, actor)),
          skipped: occurrences.length - planned.length,
          cancelled: toCancel.size,
        };
      });
    } catch (err) {
      if (isBookingConflictError(err)) {
        throw conflict('Der Raum wurde gerade von jemand anderem gebucht. Bitte wähle eine andere Zeit.');
      }
      throw err;
    }
  }

  update(actor, id, input) {
    const before = this.loadFull(toId(id));
    if (!before) throw notFound('Buchung nicht gefunden.');
    this.assertCanModify(actor, before);
    if (before.status !== 'confirmed') throw badRequest('Diese Buchung wurde bereits storniert.');
    const now = this.now();
    if (before.end_ts <= now) throw badRequest('Vergangene Buchungen können nicht mehr geändert werden.');
    const isAdmin = actor.role === 'admin';

    const roomId = input.roomId !== undefined ? toId(input.roomId, 'Raum') : before.room_id;
    const start = input.start !== undefined ? toTimestamp(input.start, 'Beginn') : before.start_ts;
    const end = input.end !== undefined ? toTimestamp(input.end, 'Ende') : before.end_ts;
    let title = before.title;
    if (input.title !== undefined) {
      title =
        before.type === 'block'
          ? optString(input.title, 'Grund', { max: 200 }) || 'Gesperrt'
          : reqString(input.title, 'Titel', { max: 200 });
    }
    const description = input.description !== undefined ? optString(input.description, 'Beschreibung', { max: 4000 }) : before.description;
    const isPrivate = input.isPrivate !== undefined ? before.type === 'booking' && toBool(input.isPrivate) : Boolean(before.is_private);
    const timeChanged = roomId !== before.room_id || start !== before.start_ts || end !== before.end_ts;
    if (timeChanged) {
      if (roomId !== before.room_id) {
        const room = this.bookableRoom(roomId);
        if (!room.bookable && !isAdmin) throw badRequest('Dieser Raum ist derzeit nicht buchbar.');
      }
      this.checkTimes(start, end, actor, { allowStartedAt: before.start_ts });
    }
    const attendees =
      input.attendees !== undefined && before.type === 'booking' ? this.normalizeAttendees(input.attendees, before.user_email) : null;

    try {
      return this.db.tx(() => {
        if (timeChanged) {
          const found = this.conflicts(roomId, start, end, before.id);
          if (found.length) {
            throw conflict('Der Raum ist in diesem Zeitraum bereits belegt.', {
              conflicts: this.conflictPayload([{ start, end, conflicts: found }], actor),
              occurrences: 1,
            });
          }
        }
        this.db.run(
          `UPDATE bookings SET room_id = ?, start_ts = ?, end_ts = ?, title = ?, description = ?, is_private = ?,
             sequence = sequence + 1, updated_at = ?, time_changed_at = CASE WHEN ? THEN ? ELSE time_changed_at END
           WHERE id = ?`,
          [roomId, start, end, title, description, isPrivate, now, timeChanged, now, before.id],
        );
        if (timeChanged) this.db.run('DELETE FROM reminders_sent WHERE booking_id = ?', [before.id]);

        let addedEmails = [];
        let removedAttendees = [];
        if (attendees) {
          const current = new Set(before.attendees.map((a) => a.email.toLowerCase()));
          const next = new Set(attendees);
          addedEmails = attendees.filter((e) => !current.has(e));
          removedAttendees = before.attendees.filter((a) => !next.has(a.email.toLowerCase()));
          for (const a of removedAttendees) {
            this.db.run('DELETE FROM booking_attendees WHERE booking_id = ? AND email = ?', [before.id, a.email]);
          }
          for (const e of addedEmails) {
            this.db.run('INSERT INTO booking_attendees (booking_id, email) VALUES (?, ?)', [before.id, e]);
          }
        }

        const after = this.loadFull(before.id);
        this.ctx.audit(actor.id, 'booking.update', `${after.room_name}: „${after.title}“ – ${formatRange(after.start_ts, after.end_ts, this.tz)}`);
        this.ctx.notifier.onUpdated(after, before, actor, { addedEmails, removedAttendees });
        this.db.afterCommit(() => {
          this.ctx.hub.broadcast('bookings-changed', { roomIds: [...new Set([before.room_id, roomId])] });
          if (timeChanged) this.ctx.watches.checkFreed(before.room_id, before.start_ts, before.end_ts);
        });
        return this.toApi(after, actor);
      });
    } catch (err) {
      if (isBookingConflictError(err)) {
        throw conflict('Der Raum wurde gerade von jemand anderem gebucht. Bitte wähle eine andere Zeit.');
      }
      throw err;
    }
  }

  /** Storniert die übergebenen (vollständig geladenen) Buchungen inkl. Benachrichtigungen. */
  cancelRows(actor, rows, reason) {
    if (!rows.length) return [];
    const now = this.now();
    for (const r of rows) {
      this.db.run(
        `UPDATE bookings SET status = 'cancelled', sequence = sequence + 1, cancel_reason = ?, cancelled_by = ?, updated_at = ?
         WHERE id = ? AND status = 'confirmed'`,
        [reason || null, actor?.id ?? null, now, r.id],
      );
      r.sequence += 1;
      r.status = 'cancelled';
    }
    const first = rows[0];
    this.ctx.audit(
      actor?.id ?? null,
      'booking.cancel',
      `${first.room_name}: „${first.title}“ – ${rows.length > 1 ? `${rows.length} Termine` : formatRange(first.start_ts, first.end_ts, this.tz)}${reason ? ` (${reason})` : ''}`,
    );
    this.ctx.notifier.onCancelled(rows, actor, reason);
    const roomIds = [...new Set(rows.map((r) => r.room_id))];
    this.db.afterCommit(() => {
      this.ctx.hub.broadcast('bookings-changed', { roomIds });
      for (const r of rows) this.ctx.watches.checkFreed(r.room_id, r.start_ts, r.end_ts);
    });
    return rows;
  }

  cancel(actor, id, { scope = 'single', reason } = {}) {
    const b = this.loadFull(toId(id));
    if (!b) throw notFound('Buchung nicht gefunden.');
    this.assertCanModify(actor, b);
    if (b.status === 'cancelled') return { cancelled: 0 };
    if (b.end_ts <= this.now()) throw badRequest('Vergangene Buchungen können nicht storniert werden.');
    const why = optString(reason, 'Grund', { max: 300 });
    return this.db.tx(() => {
      let rows = [b];
      if (scope === 'series' && b.series_id) {
        rows = this.withAttendees(
          this.db.all(`${BOOKING_SELECT} WHERE b.series_id = ? AND b.status = 'confirmed' AND b.start_ts >= ? ORDER BY b.start_ts`, [
            b.series_id,
            b.start_ts,
          ]),
        );
      }
      this.cancelRows(actor, rows, why);
      return { cancelled: rows.length };
    });
  }

  /** Laufenden Termin vorzeitig beenden – der Raum wird sofort wieder frei. */
  endNow(actor, id) {
    const b = this.loadFull(toId(id));
    if (!b) throw notFound('Buchung nicht gefunden.');
    this.assertCanModify(actor, b);
    if (b.status !== 'confirmed') throw badRequest('Diese Buchung wurde bereits storniert.');
    const now = this.now();
    if (b.start_ts > now) throw badRequest('Der Termin hat noch nicht begonnen – du kannst ihn stattdessen stornieren.');
    if (b.end_ts <= now) throw badRequest('Der Termin ist bereits beendet.');
    const newEnd = Math.max(Math.ceil(now / 60000) * 60000, b.start_ts + 60000);
    if (newEnd >= b.end_ts) return this.toApi(b, actor);
    return this.db.tx(() => {
      this.db.run('UPDATE bookings SET end_ts = ?, sequence = sequence + 1, updated_at = ? WHERE id = ?', [newEnd, now, b.id]);
      this.ctx.audit(actor.id, 'booking.end', `${b.room_name}: „${b.title}“ vorzeitig beendet`);
      this.db.afterCommit(() => {
        this.ctx.hub.broadcast('bookings-changed', { roomIds: [b.room_id] });
        this.ctx.watches.checkFreed(b.room_id, newEnd, b.end_ts);
      });
      return this.toApi(this.loadFull(b.id), actor);
    });
  }

  /** Storniert alle zukünftigen Buchungen in den angegebenen Räumen (z. B. vor dem Löschen eines Raums). */
  cancelFutureInRooms(actor, roomIds, reason) {
    if (!roomIds.length) return 0;
    const rows = this.db.all(
      `${BOOKING_SELECT} WHERE b.room_id IN (${roomIds.map(() => '?').join(',')}) AND b.status = 'confirmed' AND b.end_ts > ? ORDER BY b.start_ts`,
      [...roomIds, this.now()],
    );
    this.cancelRows(actor, this.withAttendees(rows), reason);
    return rows.length;
  }

  /** Storniert alle zukünftigen Buchungen einer Person (z. B. beim Deaktivieren des Kontos). */
  cancelFutureOfUser(actor, userId, reason) {
    const rows = this.db.all(`${BOOKING_SELECT} WHERE b.user_id = ? AND b.status = 'confirmed' AND b.end_ts > ? ORDER BY b.start_ts`, [
      userId,
      this.now(),
    ]);
    this.cancelRows(actor, this.withAttendees(rows), reason);
    return rows.length;
  }
}
