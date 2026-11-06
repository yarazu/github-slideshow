import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { loadConfig } from '../server/config.js';
import { createContext } from '../server/context.js';
import { fromLocal } from '../public/shared/time.js';

export const TZ = 'Europe/Berlin';
export const silentLog = { info() {}, warn() {}, error() {} };

/** Wanduhrzeit in Berlin -> Epoch-ms */
export const at = (day, time) => fromLocal(day, time, TZ);

export function makeClock(start) {
  return {
    t: start,
    now() {
      return this.t;
    },
    set(ms) {
      this.t = ms;
    },
    advance(ms) {
      this.t += ms;
    },
  };
}

/** Kontext mit In-Memory-Datenbank, steuerbarer Uhr und abgefangenem Mailversand. */
export function makeCtx({ now = at('2026-11-09', '08:00'), transport, configOverrides = {} } = {}) {
  const clock = makeClock(now);
  const sent = [];
  const mailTransport = transport ?? {
    async sendMail(msg) {
      sent.push(msg);
      return { messageId: `test-${sent.length}` };
    },
  };
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'raumplaner-test-'));
  const config = loadConfig({
    skipEnvFile: true,
    dataDir,
    dbFile: ':memory:',
    publicUrl: 'http://raum.test',
    timezone: TZ,
    backupIntervalHours: 0,
    smtp: { host: '', port: 587, secure: false, user: '', pass: '', from: 'Raumplaner <raum@firma.test>', rejectUnauthorized: true },
    mailLogOnly: false,
    ...configOverrides,
  });
  const ctx = createContext(config, { clock, transport: mailTransport, log: silentLog });
  // In Tests wird die Outbox explizit mit processQueue() abgearbeitet (deterministisch).
  ctx.mailer.kick = () => {};
  const cleanup = () => {
    ctx.mailer.stop();
    ctx.hub.stop();
    ctx.db.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  };
  return { ctx, clock, sent, cleanup };
}

/** Legt Benutzer und ein kleines Gebäude an. */
export async function seed(ctx) {
  const admin = await ctx.users.create({ name: 'Anna Admin', email: 'anna@firma.test', password: 'passwort1', role: 'admin' });
  const ben = await ctx.users.create({ name: 'Ben Bauer', email: 'ben@firma.test', password: 'passwort1' });
  const cara = await ctx.users.create({ name: 'Cara Klein', email: 'cara@firma.test', password: 'passwort1' });
  const building = ctx.layout.createBuilding(admin, { name: 'Zentrale' });
  const floor = ctx.layout.createFloor(admin, { buildingId: building.id, name: 'EG' });
  const rhein = ctx.layout.createRoom(admin, {
    floorId: floor.id,
    name: 'Rhein',
    capacity: 10,
    equipment: ['Beamer'],
    shape: { type: 'rect', x: 10, y: 10, w: 200, h: 100 },
  });
  const main = ctx.layout.createRoom(admin, { floorId: floor.id, name: 'Main', capacity: 4 });
  const flur = ctx.layout.createRoom(admin, { floorId: floor.id, name: 'Flur', kind: 'area' });
  const reload = (u) => ctx.users.byId(u.id);
  return { admin: reload(admin), ben: reload(ben), cara: reload(cara), building, floor, rhein, main, flur };
}

export function notificationsOf(ctx, userId) {
  return ctx.db.all('SELECT * FROM notifications WHERE user_id = ? ORDER BY id', [userId]);
}

export function outbox(ctx) {
  return ctx.db.all('SELECT * FROM email_outbox ORDER BY id');
}
