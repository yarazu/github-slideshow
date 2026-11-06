import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, test } from 'node:test';
import { HttpError } from '../server/errors.js';
import { at, makeCtx, notificationsOf, seed } from './helpers.js';

const DAY = '2026-11-10';
let env;
let s;

beforeEach(async () => {
  env = makeCtx({ now: at('2026-11-09', '08:00') });
  s = await seed(env.ctx);
});
afterEach(() => env.cleanup());

const book = (user, extra = {}) =>
  env.ctx.bookings.create(user, {
    roomId: s.rhein.id,
    title: 'Teammeeting',
    start: at(DAY, '10:00'),
    end: at(DAY, '11:00'),
    ...extra,
  });

const rejects = (fn, status, pattern) => {
  assert.throws(fn, (err) => {
    assert.ok(err instanceof HttpError, `HttpError erwartet, erhalten: ${err}`);
    assert.equal(err.status, status, err.message);
    if (pattern) assert.match(err.message, pattern);
    return true;
  });
};

describe('Doppelbuchungen sind ausgeschlossen', () => {
  test('überlappende Buchung wird abgelehnt, direkt anschließende ist erlaubt', () => {
    book(s.ben);
    rejects(() => book(s.cara, { start: at(DAY, '10:30'), end: at(DAY, '11:30') }), 409, /bereits belegt/);
    rejects(() => book(s.cara, { start: at(DAY, '09:00'), end: at(DAY, '12:00') }), 409);
    rejects(() => book(s.cara, { start: at(DAY, '10:15'), end: at(DAY, '10:45') }), 409);
    assert.doesNotThrow(() => book(s.cara, { start: at(DAY, '11:00'), end: at(DAY, '12:00') }));
    assert.doesNotThrow(() => book(s.cara, { start: at(DAY, '09:00'), end: at(DAY, '10:00') }));
    assert.doesNotThrow(() => book(s.cara, { roomId: s.main.id }));
  });

  test('die Datenbank selbst verhindert Überschneidungen (Trigger als zweite Sicherung)', () => {
    book(s.ben);
    const now = env.clock.now();
    assert.throws(
      () =>
        env.ctx.db.run(
          `INSERT INTO bookings (room_id, user_id, title, start_ts, end_ts, time_changed_at, created_at, updated_at) VALUES (?, ?, 'x', ?, ?, ?, ?, ?)`,
          [s.rhein.id, s.cara.id, at(DAY, '10:30'), at(DAY, '10:45'), now, now, now],
        ),
      /BOOKING_CONFLICT/,
    );
    const b = env.ctx.db.get(`SELECT id FROM bookings WHERE status = 'confirmed'`);
    const other = book(s.cara, { start: at(DAY, '12:00'), end: at(DAY, '13:00') }).bookings[0];
    assert.throws(
      () => env.ctx.db.run('UPDATE bookings SET start_ts = ?, end_ts = ? WHERE id = ?', [at(DAY, '10:30'), at(DAY, '12:30'), other.id]),
      /BOOKING_CONFLICT/,
    );
    assert.ok(b);
  });

  test('stornierte Buchungen geben den Raum wieder frei', () => {
    const b = book(s.ben).bookings[0];
    env.ctx.bookings.cancel(s.ben, b.id);
    assert.doesNotThrow(() => book(s.cara));
  });

  test('Verschieben in einen belegten Zeitraum wird abgelehnt', () => {
    book(s.ben);
    const b2 = book(s.cara, { start: at(DAY, '12:00'), end: at(DAY, '13:00') }).bookings[0];
    rejects(() => env.ctx.bookings.update(s.cara, b2.id, { start: at(DAY, '10:30'), end: at(DAY, '11:30') }), 409);
    const moved = env.ctx.bookings.update(s.cara, b2.id, { start: at(DAY, '11:00'), end: at(DAY, '12:30') });
    assert.equal(moved.start, at(DAY, '11:00'));
  });

  test('Konfliktfehler enthalten die blockierende Buchung', () => {
    book(s.ben);
    try {
      book(s.cara, { start: at(DAY, '10:30'), end: at(DAY, '11:30') });
      assert.fail('Konflikt erwartet');
    } catch (err) {
      assert.equal(err.extra.conflicts.length, 1);
      assert.equal(err.extra.conflicts[0].bookings[0].user.name, 'Ben Bauer');
    }
  });
});

describe('Regeln und Berechtigungen', () => {
  test('Buchungen in der Vergangenheit und Bereiche ohne Buchbarkeit werden abgelehnt', () => {
    rejects(() => book(s.ben, { start: at('2026-11-08', '10:00'), end: at('2026-11-08', '11:00') }), 400, /Vergangenheit/);
    rejects(() => book(s.ben, { start: at(DAY, '11:00'), end: at(DAY, '10:00') }), 400, /Ende/);
    rejects(() => book(s.ben, { roomId: s.flur.id }), 400, /nicht gebucht/);
    rejects(() => book(s.ben, { title: '   ' }), 400, /Titel/);
  });

  test('maximale Dauer gilt für Mitarbeitende, nicht für Admins', () => {
    rejects(() => book(s.ben, { start: at(DAY, '07:00'), end: at(DAY, '18:00') }), 400, /höchstens/);
    assert.doesNotThrow(() => book(s.admin, { start: at(DAY, '07:00'), end: at(DAY, '18:00') }));
  });

  test('nicht buchbare Räume können nur von Admins belegt werden', () => {
    env.ctx.layout.updateRoom(s.admin, s.main.id, { bookable: false });
    rejects(() => book(s.ben, { roomId: s.main.id }), 400, /nicht buchbar/);
  });

  test('nur Buchende und Admins dürfen ändern oder stornieren', () => {
    const b = book(s.ben).bookings[0];
    rejects(() => env.ctx.bookings.cancel(s.cara, b.id), 403);
    rejects(() => env.ctx.bookings.update(s.cara, b.id, { title: 'Gekapert' }), 403);
    assert.equal(env.ctx.bookings.cancel(s.admin, b.id).cancelled, 1);
    // Admin hat storniert -> Ben wird benachrichtigt
    const n = notificationsOf(env.ctx, s.ben.id);
    assert.equal(n.length, 1);
    assert.match(n[0].title, /storniert/);
  });

  test('private Termine zeigen anderen nur „Privater Termin“', () => {
    const b = book(s.ben, { title: 'Gehaltsgespräch', isPrivate: true, attendees: ['cara@firma.test'] }).bookings[0];
    const outsider = { id: 999, role: 'user', email: 'x@firma.test' };
    assert.equal(env.ctx.bookings.get(b.id, outsider).title, 'Privater Termin');
    assert.equal(env.ctx.bookings.get(b.id, outsider).attendees.length, 0);
    assert.equal(env.ctx.bookings.get(b.id, s.cara).title, 'Gehaltsgespräch');
    assert.equal(env.ctx.bookings.get(b.id, s.admin).title, 'Gehaltsgespräch');
  });

  test('Teilnehmende werden normalisiert und geprüft', () => {
    const b = book(s.ben, { attendees: ['Cara <CARA@firma.test>', 'cara@firma.test', 'ben@firma.test', 'extern@partner.test'] }).bookings[0];
    assert.deepEqual(b.attendees.map((a) => a.email).sort(), ['cara@firma.test', 'extern@partner.test']);
    rejects(() => book(s.ben, { roomId: s.main.id, attendees: ['kein-email'] }), 400, /Ungültige E-Mail/);
  });
});

describe('Serientermine', () => {
  test('Wöchentliche Serie legt alle Termine an', () => {
    const r = book(s.ben, { recurrence: { freq: 'weekly', until: '2026-12-01' } });
    assert.equal(r.bookings.length, 4);
    assert.ok(r.bookings.every((b) => b.seriesId && b.seriesId === r.bookings[0].seriesId));
  });

  test('belegte Einzeltermine blockieren die Serie – oder werden auf Wunsch übersprungen', () => {
    book(s.cara, { start: at('2026-11-17', '10:30'), end: at('2026-11-17', '11:30') });
    rejects(() => book(s.ben, { recurrence: { freq: 'weekly', until: '2026-12-01' } }), 409, /1 von 4/);
    assert.equal(env.ctx.db.get(`SELECT COUNT(*) AS n FROM bookings WHERE user_id = ?`, [s.ben.id]).n, 0, 'nichts darf halb angelegt sein');
    const r = book(s.ben, { recurrence: { freq: 'weekly', until: '2026-12-01' }, skipConflicts: true });
    assert.equal(r.bookings.length, 3);
    assert.equal(r.skipped, 1);
  });

  test('„Diesen und alle folgenden“ storniert nur die Folgetermine', () => {
    const r = book(s.ben, { recurrence: { freq: 'weekly', until: '2026-12-01' } });
    const res = env.ctx.bookings.cancel(s.ben, r.bookings[2].id, { scope: 'series' });
    assert.equal(res.cancelled, 2);
    const left = env.ctx.db.all(`SELECT id FROM bookings WHERE status = 'confirmed' ORDER BY start_ts`).map((x) => x.id);
    assert.deepEqual(left, [r.bookings[0].id, r.bookings[1].id]);
  });
});

describe('Sperrungen und vorzeitiges Beenden', () => {
  test('eine Sperrung storniert betroffene Buchungen und benachrichtigt die Buchenden', () => {
    book(s.ben);
    book(s.cara, { start: at(DAY, '14:00'), end: at(DAY, '15:00') });
    rejects(() => book(s.ben, { type: 'block', start: at(DAY, '08:00'), end: at(DAY, '18:00') }), 403);
    const r = book(s.admin, { type: 'block', title: 'Malerarbeiten', start: at(DAY, '08:00'), end: at(DAY, '18:00') });
    assert.equal(r.cancelled, 2);
    for (const u of [s.ben, s.cara]) {
      const n = notificationsOf(env.ctx, u.id);
      assert.equal(n.length, 1);
      assert.match(n[0].body, /Malerarbeiten/);
    }
    rejects(() => book(s.ben, { start: at(DAY, '12:00'), end: at(DAY, '13:00') }), 409);
  });

  test('ein laufender Termin kann vorzeitig beendet werden – der Rest ist sofort frei', () => {
    const b = book(s.ben, { start: at('2026-11-09', '08:00'), end: at('2026-11-09', '10:00') }).bookings[0];
    env.clock.set(at('2026-11-09', '08:40'));
    const ended = env.ctx.bookings.endNow(s.ben, b.id);
    assert.equal(ended.end, at('2026-11-09', '08:40'));
    assert.doesNotThrow(() => book(s.cara, { start: at('2026-11-09', '08:45'), end: at('2026-11-09', '09:30') }));
  });

  test('Löschen eines Raums storniert dessen zukünftige Buchungen mit Benachrichtigung', () => {
    book(s.ben, { attendees: ['cara@firma.test'] });
    const r = env.ctx.layout.deleteRoom(s.admin, s.rhein.id);
    assert.equal(r.cancelledBookings, 1);
    assert.equal(notificationsOf(env.ctx, s.ben.id).length, 1);
    assert.ok(notificationsOf(env.ctx, s.cara.id).some((n) => n.type === 'cancelled'));
  });

  test('Deaktivieren eines Kontos gibt dessen zukünftige Räume frei', () => {
    book(s.ben);
    const r = env.ctx.users.adminUpdate(s.admin, s.ben.id, { active: false });
    assert.equal(r.cancelledBookings, 1);
    assert.doesNotThrow(() => book(s.cara));
  });

  test('die letzte Administratorin kann sich nicht selbst entmachten', () => {
    rejects(() => env.ctx.users.adminUpdate(s.admin, s.admin.id, { role: 'user' }), 400, /mindestens eine/);
  });
});
