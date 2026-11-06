import assert from 'node:assert/strict';
import { afterEach, describe, test } from 'node:test';
import { MAX_ATTEMPTS } from '../server/mailer.js';
import { at, makeCtx, notificationsOf, outbox, seed } from './helpers.js';

const DAY = '2026-11-10';
let env;
afterEach(() => env?.cleanup());

async function setup(opts) {
  env = makeCtx({ now: at('2026-11-09', '08:00'), ...opts });
  return seed(env.ctx);
}

const booking = (s, extra = {}) => ({
  roomId: s.rhein.id,
  title: 'Quartalsplanung',
  start: at(DAY, '10:00'),
  end: at(DAY, '11:00'),
  ...extra,
});

describe('Benachrichtigungen bei Buchungen', () => {
  test('Bestätigung an Buchende, Einladungen an Teilnehmende – mit Kalendereinladung', async () => {
    const s = await setup();
    env.ctx.bookings.create(s.ben, booking(s, { attendees: ['cara@firma.test', 'gast@partner.test'] }));

    const mails = outbox(env.ctx);
    assert.deepEqual(mails.map((m) => m.to_email).sort(), ['ben@firma.test', 'cara@firma.test', 'gast@partner.test']);
    const confirm = mails.find((m) => m.to_email === 'ben@firma.test');
    assert.match(confirm.subject, /^Buchung bestätigt: Quartalsplanung/);
    assert.equal(confirm.ics_method, 'REQUEST');
    assert.match(confirm.ics, /BEGIN:VCALENDAR\r\n/);
    assert.match(confirm.ics, /METHOD:REQUEST/);
    assert.match(confirm.ics, /DTSTART:20261110T090000Z/);
    assert.match(confirm.ics, /LOCATION:Rhein · EG · Zentrale/);
    assert.match(confirm.ics, /UID:booking-\d+@raum\.test/);

    // Cara hat ein Konto -> zusätzlich In-App-Nachricht; Ben (selbst gebucht) nicht
    const cara = notificationsOf(env.ctx, s.cara.id);
    assert.equal(cara.length, 1);
    assert.equal(cara[0].type, 'invite');
    assert.equal(notificationsOf(env.ctx, s.ben.id).length, 0);

    // Zustellung über die Outbox
    assert.equal(await env.ctx.mailer.processQueue(), 3);
    assert.equal(env.sent.length, 3);
    const invite = env.sent.find((m) => m.to === 'gast@partner.test');
    assert.equal(invite.icalEvent.method, 'REQUEST');
    assert.match(invite.subject, /^Einladung: Quartalsplanung/);
    assert.match(invite.html, /Ben Bauer hat dich eingeladen/);
  });

  test('Absage verschickt CANCEL-Kalenderdateien mit gleicher UID', async () => {
    const s = await setup();
    const b = env.ctx.bookings.create(s.ben, booking(s, { attendees: ['cara@firma.test'] })).bookings[0];
    const uid = /UID:(\S+)/.exec(outbox(env.ctx)[0].ics)[1];
    env.ctx.bookings.cancel(s.ben, b.id, { reason: 'Kunde hat abgesagt' });
    const cancels = outbox(env.ctx).filter((m) => m.ics_method === 'CANCEL');
    assert.equal(cancels.length, 2);
    for (const m of cancels) {
      assert.match(m.ics, new RegExp(`UID:${uid.replace('.', '\\.')}`));
      assert.match(m.ics, /STATUS:CANCELLED/);
      assert.match(m.ics, /SEQUENCE:1/);
      assert.match(m.text_body, /Kunde hat abgesagt/);
    }
    assert.ok(notificationsOf(env.ctx, s.cara.id).some((n) => n.type === 'cancelled'));
  });

  test('Änderungen werden mit alter und neuer Zeit gemeldet, neue Teilnehmende eingeladen', async () => {
    const s = await setup();
    const b = env.ctx.bookings.create(s.ben, booking(s, { attendees: ['cara@firma.test'] })).bookings[0];
    env.ctx.db.run('DELETE FROM email_outbox');
    env.ctx.bookings.update(s.ben, b.id, { start: at(DAY, '14:00'), end: at(DAY, '15:00'), attendees: ['cara@firma.test', 'neu@partner.test'] });
    const mails = outbox(env.ctx);
    const toCara = mails.find((m) => m.to_email === 'cara@firma.test');
    assert.match(toCara.subject, /^Geändert:/);
    assert.match(toCara.text_body, /14:00–15:00/);
    assert.match(toCara.text_body, /vorher: .*10:00–11:00/);
    assert.match(mails.find((m) => m.to_email === 'neu@partner.test').subject, /^Einladung:/);
  });

  test('wer E-Mails abbestellt hat, bekommt trotzdem In-App-Benachrichtigungen', async () => {
    const s = await setup();
    env.ctx.users.updateProfile(s.cara, { notifyEmail: false });
    env.ctx.bookings.create(s.ben, booking(s, { attendees: ['cara@firma.test'] }));
    assert.equal(outbox(env.ctx).filter((m) => m.to_email === 'cara@firma.test').length, 0);
    assert.equal(notificationsOf(env.ctx, s.cara.id).length, 1);
  });

  test('scheitert die Buchung, wird auch nichts verschickt (Outbox ist Teil der Transaktion)', async () => {
    const s = await setup();
    env.ctx.bookings.create(s.ben, booking(s));
    const before = outbox(env.ctx).length;
    assert.throws(() => env.ctx.bookings.create(s.cara, booking(s, { attendees: ['ben@firma.test'] })));
    assert.equal(outbox(env.ctx).length, before);
    assert.equal(notificationsOf(env.ctx, s.ben.id).length, 0);
  });

  test('Serien erhalten eine gebündelte E-Mail mit allen Terminen', async () => {
    const s = await setup();
    env.ctx.bookings.create(s.ben, booking(s, { recurrence: { freq: 'weekly', until: '2026-12-01' }, attendees: ['cara@firma.test'] }));
    const mails = outbox(env.ctx);
    assert.equal(mails.length, 2);
    const att = JSON.parse(mails[0].attachments);
    assert.equal(att[0].filename, 'termine.ics');
    assert.equal((att[0].content.match(/BEGIN:VEVENT/g) || []).length, 4);
    assert.equal(notificationsOf(env.ctx, s.cara.id).length, 1);
  });
});

describe('Erinnerungen', () => {
  test('werden genau einmal zum eingestellten Zeitpunkt verschickt', async () => {
    const s = await setup();
    env.ctx.users.updateProfile(s.cara, { reminderMinutes: 30 });
    env.ctx.bookings.create(s.ben, booking(s, { attendees: ['cara@firma.test', 'gast@partner.test'] }));
    env.ctx.db.run('DELETE FROM email_outbox');

    env.clock.set(at(DAY, '09:20'));
    assert.equal(env.ctx.reminders.tick(), 0);
    env.clock.set(at(DAY, '09:31'));
    assert.equal(env.ctx.reminders.tick(), 1, 'Cara (30 Min.)');
    env.clock.set(at(DAY, '09:46'));
    assert.equal(env.ctx.reminders.tick(), 1, 'Ben (15 Min.)');
    assert.equal(env.ctx.reminders.tick(), 0, 'keine doppelten Erinnerungen');

    const reminders = outbox(env.ctx);
    assert.deepEqual(reminders.map((m) => m.to_email), ['cara@firma.test', 'ben@firma.test']);
    assert.match(reminders[1].subject, /^Erinnerung: Quartalsplanung um 10:00 Uhr/);
    assert.ok(notificationsOf(env.ctx, s.ben.id).some((n) => n.type === 'reminder'));
  });

  test('werden nachgeholt, wenn der Server zum Zeitpunkt aus war – aber nicht nach Beginn', async () => {
    const s = await setup();
    env.ctx.bookings.create(s.ben, booking(s));
    env.clock.set(at(DAY, '09:58'));
    assert.equal(env.ctx.reminders.tick(), 1);
    const other = env.ctx.bookings.create(s.ben, booking(s, { roomId: s.main.id, start: at(DAY, '12:00'), end: at(DAY, '13:00') }));
    assert.ok(other);
    env.clock.set(at(DAY, '12:01'));
    assert.equal(env.ctx.reminders.tick(), 0);
  });

  test('kurzfristige Buchungen lösen keine sofortige Erinnerung aus; Verschieben erinnert neu', async () => {
    const s = await setup();
    env.clock.set(at(DAY, '09:50'));
    const b = env.ctx.bookings.create(s.ben, booking(s)).bookings[0];
    assert.equal(env.ctx.reminders.tick(), 0);
    env.ctx.bookings.update(s.ben, b.id, { start: at(DAY, '15:00'), end: at(DAY, '16:00') });
    env.clock.set(at(DAY, '14:46'));
    assert.equal(env.ctx.reminders.tick(), 1);
  });
});

describe('Raum-Wunsch: „Benachrichtigen, wenn frei“', () => {
  test('meldet sich, sobald der gewünschte Zeitraum frei wird', async () => {
    const s = await setup();
    const blocking = env.ctx.bookings.create(s.ben, booking(s)).bookings[0];
    assert.deepEqual(env.ctx.watches.create(s.cara, { roomId: s.main.id, start: at(DAY, '10:00'), end: at(DAY, '11:00') }), { free: true });
    const w = env.ctx.watches.create(s.cara, { roomId: s.rhein.id, start: at(DAY, '10:00'), end: at(DAY, '11:00') });
    assert.equal(w.free, false);
    assert.equal(env.ctx.watches.list(s.cara).length, 1);

    env.ctx.bookings.cancel(s.ben, blocking.id);
    const n = notificationsOf(env.ctx, s.cara.id).find((x) => x.type === 'watch');
    assert.ok(n, 'Cara wird benachrichtigt');
    assert.match(n.link, /^#\/buchen\?room=\d+&start=\d+&end=\d+$/);
    assert.ok(outbox(env.ctx).some((m) => m.to_email === 'cara@firma.test' && /^Raum frei: Rhein/.test(m.subject)));
    assert.equal(env.ctx.watches.list(s.cara).length, 0, 'Wunsch ist erledigt');
  });

  test('meldet sich nicht, solange der Zeitraum noch teilweise belegt ist', async () => {
    const s = await setup();
    const a = env.ctx.bookings.create(s.ben, booking(s, { end: at(DAY, '10:30') })).bookings[0];
    env.ctx.bookings.create(s.admin, booking(s, { start: at(DAY, '10:30'), end: at(DAY, '11:00') }));
    env.ctx.watches.create(s.cara, { roomId: s.rhein.id, start: at(DAY, '10:00'), end: at(DAY, '11:00') });
    env.ctx.bookings.cancel(s.ben, a.id);
    assert.equal(notificationsOf(env.ctx, s.cara.id).filter((x) => x.type === 'watch').length, 0);
    assert.equal(env.ctx.watches.list(s.cara).length, 1);
  });
});

describe('Zuverlässiger E-Mail-Versand', () => {
  test('fehlgeschlagene Zustellung wird mit wachsendem Abstand wiederholt und dann als Fehler markiert', async () => {
    let attempts = 0;
    const s = await setup({
      transport: {
        async sendMail() {
          attempts += 1;
          throw new Error('SMTP nicht erreichbar');
        },
      },
    });
    env.ctx.bookings.create(s.ben, booking(s));
    const id = outbox(env.ctx)[0].id;

    await env.ctx.mailer.processQueue();
    let m = env.ctx.db.get('SELECT * FROM email_outbox WHERE id = ?', [id]);
    assert.equal(m.status, 'pending');
    assert.equal(m.attempts, 1);
    assert.equal(m.next_attempt_at - env.clock.now(), 60000);
    assert.match(m.last_error, /SMTP nicht erreichbar/);

    await env.ctx.mailer.processQueue();
    assert.equal(attempts, 1, 'vor Ablauf der Wartezeit kein neuer Versuch');

    for (let i = 1; i < MAX_ATTEMPTS; i++) {
      env.clock.advance(24 * 3600000);
      await env.ctx.mailer.processQueue();
    }
    m = env.ctx.db.get('SELECT * FROM email_outbox WHERE id = ?', [id]);
    assert.equal(m.status, 'failed');
    assert.equal(attempts, MAX_ATTEMPTS);

    assert.ok(env.ctx.mailer.retry(id));
    assert.equal(env.ctx.db.get('SELECT status FROM email_outbox WHERE id = ?', [id]).status, 'pending');
  });

  test('nach einem Neustart werden offene E-Mails zugestellt', async () => {
    const s = await setup();
    env.ctx.bookings.create(s.ben, booking(s));
    // Simuliert: Prozess war beendet, bevor zugestellt wurde -> beim nächsten Durchlauf wird nachgeholt
    assert.equal(env.ctx.db.get(`SELECT COUNT(*) AS n FROM email_outbox WHERE status = 'pending'`).n, 1);
    assert.equal(await env.ctx.mailer.processQueue(), 1);
    assert.equal(env.ctx.db.get(`SELECT COUNT(*) AS n FROM email_outbox WHERE status = 'sent'`).n, 1);
  });
});
