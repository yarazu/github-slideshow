import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  dateKey,
  dayBounds,
  expandRecurrence,
  formatRange,
  fromLocal,
  MAX_OCCURRENCES,
  timeKey,
  weekdayOfKey,
} from '../public/shared/time.js';

const TZ = 'Europe/Berlin';

test('Wanduhrzeit wird korrekt in UTC umgerechnet (Winter- und Sommerzeit)', () => {
  assert.equal(fromLocal('2026-11-09', '10:00', TZ), Date.parse('2026-11-09T09:00:00Z'));
  assert.equal(fromLocal('2026-07-01', '10:00', TZ), Date.parse('2026-07-01T08:00:00Z'));
  assert.equal(fromLocal('2026-11-09', '24:00', TZ), Date.parse('2026-11-09T23:00:00Z'));
  assert.equal(dateKey(Date.parse('2026-11-09T23:30:00Z'), TZ), '2026-11-10');
  assert.equal(timeKey(Date.parse('2026-07-01T08:15:00Z'), TZ), '10:15');
  assert.ok(Number.isNaN(fromLocal('2026-02-30', '10:00', TZ)));
});

test('Tage mit Zeitumstellung haben 23 bzw. 25 Stunden', () => {
  const spring = dayBounds('2026-03-29', TZ);
  const autumn = dayBounds('2026-10-25', TZ);
  assert.equal(spring.end - spring.start, 23 * 3600000);
  assert.equal(autumn.end - autumn.start, 25 * 3600000);
  assert.ok(Number.isFinite(fromLocal('2026-03-29', '02:30', TZ)));
});

test('Wöchentliche Serie bleibt über die Zeitumstellung um 10:00 Uhr', () => {
  const start = fromLocal('2026-10-15', '10:00', TZ);
  const occ = expandRecurrence(start, start + 3600000, { freq: 'weekly', until: '2026-11-05' }, TZ);
  assert.equal(occ.length, 4);
  assert.deepEqual(
    occ.map((o) => `${dateKey(o.start, TZ)} ${timeKey(o.start, TZ)}-${timeKey(o.end, TZ)}`),
    ['2026-10-15 10:00-11:00', '2026-10-22 10:00-11:00', '2026-10-29 10:00-11:00', '2026-11-05 10:00-11:00'],
  );
  // Vor und nach der Umstellung unterscheidet sich die UTC-Zeit um eine Stunde
  assert.equal(new Date(occ[0].start).getUTCHours(), 8);
  assert.equal(new Date(occ[2].start).getUTCHours(), 9);
});

test('Werktägliche Serie überspringt Wochenenden', () => {
  const start = fromLocal('2026-11-06', '09:00', TZ); // Freitag
  const occ = expandRecurrence(start, start + 1800000, { freq: 'workdays', until: '2026-11-11' }, TZ);
  assert.deepEqual(
    occ.map((o) => dateKey(o.start, TZ)),
    ['2026-11-06', '2026-11-09', '2026-11-10', '2026-11-11'],
  );
  for (const o of occ) assert.ok(![0, 6].includes(weekdayOfKey(dateKey(o.start, TZ))));
});

test('Monatliche Serie überspringt Monate ohne passenden Tag', () => {
  const start = fromLocal('2026-01-31', '09:00', TZ);
  const occ = expandRecurrence(start, start + 3600000, { freq: 'monthly', until: '2026-06-30' }, TZ);
  assert.deepEqual(
    occ.map((o) => dateKey(o.start, TZ)),
    ['2026-01-31', '2026-03-31', '2026-05-31'],
  );
});

test('Serien sind auf eine Höchstzahl an Terminen begrenzt', () => {
  const start = fromLocal('2026-11-09', '09:00', TZ);
  const occ = expandRecurrence(start, start + 3600000, { freq: 'workdays', until: '2029-12-31' }, TZ);
  assert.equal(occ.length, MAX_OCCURRENCES);
  assert.throws(() => expandRecurrence(start, start + 1, { freq: 'weekly' }, TZ), /Enddatum/);
  assert.throws(() => expandRecurrence(start, start + 1, { freq: 'hourly', until: '2027-01-01' }, TZ), /Unbekannte/);
});

test('Zeiträume werden verständlich formatiert', () => {
  const s = fromLocal('2026-11-12', '10:00', TZ);
  assert.equal(formatRange(s, s + 3600000, TZ), 'Do., 12.11.2026, 10:00–11:00 Uhr');
  assert.equal(formatRange(s, fromLocal('2026-11-13', '00:00', TZ), TZ), 'Do., 12.11.2026, 10:00–24:00 Uhr');
  assert.match(formatRange(s, fromLocal('2026-11-13', '12:00', TZ), TZ), /^Do\., 12\.11\.2026, 10:00 Uhr – Fr\., 13\.11\.2026, 12:00 Uhr$/);
});
