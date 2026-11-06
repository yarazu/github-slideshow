import assert from 'node:assert/strict';
import http from 'node:http';
import { after, before, describe, test } from 'node:test';
import { createApp } from '../server/app.js';
import { makeCtx } from './helpers.js';

let env;
let server;
let base;

before(async () => {
  env = makeCtx({ now: Date.now() });
  env.clock.now = () => Date.now();
  server = http.createServer(createApp(env.ctx));
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  env.ctx.hub.stop();
  server.closeAllConnections?.();
  await new Promise((resolve) => server.close(resolve));
  env.cleanup();
});

/** Minimaler HTTP-Client mit Cookie-Speicher. */
function client() {
  let cookie = '';
  return async function call(method, path, body, { csrf = true, headers = {} } = {}) {
    const h = { ...headers };
    if (csrf) h['X-Requested-With'] = 'raumplaner';
    if (cookie) h.Cookie = cookie;
    let payload;
    if (body !== undefined && !(body instanceof Uint8Array)) {
      h['Content-Type'] = 'application/json';
      payload = JSON.stringify(body);
    } else payload = body;
    const res = await fetch(base + path, { method, headers: h, body: payload });
    const set = res.headers.get('set-cookie');
    if (set) cookie = set.split(';')[0];
    const type = res.headers.get('content-type') || '';
    const data = type.includes('json') ? await res.json() : await res.text();
    return { status: res.status, data, headers: res.headers };
  };
}

const hour = 3600000;
const nextHour = () => Math.ceil(Date.now() / hour) * hour + 2 * hour;

describe('HTTP-API', () => {
  const admin = client();
  const ben = client();
  const cara = client();
  const anon = client();
  let room;
  let floor;

  test('Ersteinrichtung legt genau einmal ein Admin-Konto an', async () => {
    assert.equal((await anon('GET', '/api/config')).data.needsSetup, true);
    const body = { orgName: 'Muster GmbH', name: 'Anna Admin', email: 'anna@firma.test', password: 'passwort1' };
    assert.equal((await admin('POST', '/api/setup', body, { csrf: false })).status, 403, 'ohne CSRF-Header abgelehnt');
    const r = await admin('POST', '/api/setup', body);
    assert.equal(r.status, 201);
    assert.equal(r.data.user.role, 'admin');
    assert.equal((await anon('POST', '/api/setup', { ...body, email: 'x@firma.test' })).status, 403);
    const cfg = (await anon('GET', '/api/config')).data;
    assert.equal(cfg.needsSetup, false);
    assert.equal(cfg.orgName, 'Muster GmbH');
  });

  test('Sicherheits-Header und Zugriffsschutz', async () => {
    const r = await anon('GET', '/api/layout');
    assert.equal(r.status, 401);
    assert.match(r.headers.get('content-security-policy'), /default-src 'self'/);
    assert.equal(r.headers.get('x-content-type-options'), 'nosniff');
    const health = await anon('GET', '/api/health');
    assert.equal(health.data.status, 'ok');
  });

  test('Registrierung, Anmeldung und Rollen', async () => {
    assert.equal((await ben('POST', '/api/auth/register', { name: 'Ben Bauer', email: 'ben@firma.test', password: 'passwort1' })).status, 201);
    assert.equal((await cara('POST', '/api/auth/register', { name: 'Cara Klein', email: 'cara@firma.test', password: 'kurz' })).status, 400);
    assert.equal((await cara('POST', '/api/auth/register', { name: 'Cara Klein', email: 'cara@firma.test', password: 'passwort1' })).status, 201);
    assert.equal((await cara('POST', '/api/auth/logout')).status, 200);
    assert.equal((await cara('GET', '/api/me')).status, 401);
    assert.equal((await cara('POST', '/api/auth/login', { email: 'cara@firma.test', password: 'falsch!!' })).status, 401);
    assert.equal((await cara('POST', '/api/auth/login', { email: 'CARA@firma.test', password: 'passwort1' })).status, 200);
    assert.equal((await ben('POST', '/api/buildings', { name: 'Gebäude' })).status, 403, 'nur Admins verwalten das Layout');
  });

  test('Admins hinterlegen Gebäude, Etage, Grundriss und Räume', async () => {
    const b = await admin('POST', '/api/buildings', { name: 'Zentrale', address: 'Hauptstr. 1' });
    assert.equal(b.status, 201);
    floor = (await admin('POST', '/api/floors', { buildingId: b.data.id, name: 'EG' })).data;
    room = (
      await admin('POST', '/api/rooms', {
        floorId: floor.id,
        name: 'Rhein',
        capacity: 8,
        equipment: ['Beamer', 'Videokonferenz'],
        shape: { type: 'poly', points: [[0, 0], [100, 0], [100, 50], [0, 50]] },
      })
    ).data;
    assert.equal(room.shape.type, 'poly');

    const png = Uint8Array.from(Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex'));
    const up = await admin('PUT', `/api/floors/${floor.id}/image?width=1000&height=500`, png, { headers: { 'Content-Type': 'image/png' } });
    assert.equal(up.status, 200, JSON.stringify(up.data));
    assert.equal(up.data.height, 500);
    const img = await ben('GET', up.data.imageUrl);
    assert.equal(img.status, 200);
    assert.equal(img.headers.get('content-type'), 'image/png');
    const bad = await admin('PUT', `/api/floors/${floor.id}/image`, Uint8Array.from(Buffer.from('hallo')), {
      headers: { 'Content-Type': 'image/png' },
    });
    assert.equal(bad.status, 400);

    const layout = (await ben('GET', '/api/layout')).data;
    assert.equal(layout.rooms.length, 1);
    assert.deepEqual(layout.rooms[0].equipment, ['Beamer', 'Videokonferenz']);
  });

  test('gleichzeitige Buchungsversuche: genau einer gewinnt', async () => {
    const start = nextHour();
    const attempts = await Promise.all(
      Array.from({ length: 20 }, (_, i) =>
        (i % 2 ? ben : cara)('POST', '/api/bookings', { roomId: room.id, title: `Versuch ${i}`, start, end: start + hour }),
      ),
    );
    const ok = attempts.filter((r) => r.status === 201);
    const conflicts = attempts.filter((r) => r.status === 409);
    assert.equal(ok.length, 1);
    assert.equal(conflicts.length, 19);
    assert.match(conflicts[0].data.message, /belegt/);
    const list = (await admin('GET', `/api/bookings?from=${start - hour}&to=${start + 2 * hour}`)).data;
    assert.equal(list.length, 1);
  });

  test('Live-Kanal liefert Benachrichtigungen sofort', async () => {
    const meCara = (await cara('GET', '/api/me')).data;
    const login = await fetch(base + '/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'raumplaner' },
      body: JSON.stringify({ email: 'cara@firma.test', password: 'passwort1' }),
    });
    const cookie = login.headers.get('set-cookie').split(';')[0];
    const events = [];
    const req = http.get(base + '/api/events', { headers: { Cookie: cookie } });
    const gotNotification = new Promise((resolve, reject) => {
      req.on('response', (res) => {
        assert.equal(res.headers['content-type'], 'text/event-stream; charset=utf-8');
        let buf = '';
        res.on('data', (chunk) => {
          buf += chunk;
          let idx;
          while ((idx = buf.indexOf('\n\n')) >= 0) {
            const block = buf.slice(0, idx);
            buf = buf.slice(idx + 2);
            const ev = /^event: (.+)$/m.exec(block)?.[1];
            const data = /^data: (.+)$/m.exec(block)?.[1];
            if (ev) events.push({ ev, data: JSON.parse(data) });
            if (ev === 'notification') resolve(JSON.parse(data));
          }
        });
      });
      req.on('error', reject);
      setTimeout(() => reject(new Error('Keine Live-Benachrichtigung erhalten')), 3000).unref();
    });
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(events[0]?.ev, 'hello');
    const start = nextHour() + 3 * hour;
    const created = await ben('POST', '/api/bookings', {
      roomId: room.id,
      title: 'Abstimmung',
      start,
      end: start + hour,
      attendees: [meCara.user.email],
    });
    assert.equal(created.status, 201);
    const n = await gotNotification;
    req.destroy();
    assert.equal(n.type, 'invite');
    assert.match(n.title, /Abstimmung/);
    assert.ok(n.unreadCount >= 1);
    assert.ok(events.some((e) => e.ev === 'bookings-changed'));
  });

  test('persönliches Kalender-Abo enthält die eigenen Termine', async () => {
    const me = (await cara('GET', '/api/me')).data;
    const path = new URL(me.calendarUrl).pathname;
    const feed = await anon('GET', path);
    assert.equal(feed.status, 200);
    assert.match(feed.headers.get('content-type'), /text\/calendar/);
    assert.match(feed.data, /BEGIN:VCALENDAR/);
    assert.match(feed.data, /SUMMARY:Abstimmung/);
    assert.equal((await anon('GET', '/cal/falsches-token.ics')).status, 404);
  });

  test('Benachrichtigungen lassen sich abrufen und als gelesen markieren', async () => {
    const list = (await cara('GET', '/api/notifications')).data;
    assert.ok(list.unreadCount >= 1);
    const r = await cara('POST', '/api/notifications/read', { all: true });
    assert.equal(r.data.unreadCount, 0);
  });

  test('Anmeldeversuche werden begrenzt', async () => {
    const attacker = client();
    let last;
    for (let i = 0; i < 11; i++) {
      last = await attacker('POST', '/api/auth/login', { email: 'ben@firma.test', password: `falsch-${i}` });
    }
    assert.equal(last.status, 429);
  });
});
