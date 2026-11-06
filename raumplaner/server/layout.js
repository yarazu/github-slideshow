import { badRequest, notFound } from './errors.js';
import { optString, reqString, toBool, toId, toInt, toNumber } from './validate.js';

const KINDS = ['room', 'desk', 'area'];
export const IMAGE_TYPES = ['image/png', 'image/jpeg', 'image/webp', 'image/gif', 'image/svg+xml'];

/** Erkennt das Bildformat anhand der ersten Bytes (Dateiendung/Content-Type allein ist nicht vertrauenswürdig). */
export function detectImage(buf) {
  if (!buf || !buf.length) return null;
  if (buf.length > 8 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return 'image/png';
  if (buf.length > 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg';
  if (buf.length > 6 && buf.subarray(0, 4).toString('ascii') === 'GIF8') return 'image/gif';
  if (buf.length > 12 && buf.subarray(0, 4).toString('ascii') === 'RIFF' && buf.subarray(8, 12).toString('ascii') === 'WEBP') {
    return 'image/webp';
  }
  const head = buf.subarray(0, 2048).toString('utf8').replace(/^﻿/, '').trimStart();
  if (/^(<\?xml|<svg|<!--|<!doctype svg)/i.test(head) && buf.toString('utf8').includes('<svg')) return 'image/svg+xml';
  return null;
}

const round1 = (n) => Math.round(n * 10) / 10;

export function normalizeShape(shape, floor) {
  if (shape === null || shape === undefined || shape === '') return null;
  let s = shape;
  if (typeof s === 'string') {
    try {
      s = JSON.parse(s);
    } catch {
      throw badRequest('Ungültige Raumform.');
    }
  }
  const limit = Math.max(floor.width, floor.height) * 3;
  const num = (v) => round1(toNumber(v, 'Koordinate', { min: -limit, max: limit }));
  if (s.type === 'rect') {
    const out = { type: 'rect', x: num(s.x), y: num(s.y), w: num(s.w), h: num(s.h) };
    if (out.w < 1 || out.h < 1) throw badRequest('Die Raumform ist zu klein.');
    return JSON.stringify(out);
  }
  if (s.type === 'poly') {
    if (!Array.isArray(s.points) || s.points.length < 3 || s.points.length > 200) {
      throw badRequest('Ein Polygon braucht 3 bis 200 Eckpunkte.');
    }
    return JSON.stringify({ type: 'poly', points: s.points.map((p) => [num(p?.[0]), num(p?.[1])]) });
  }
  throw badRequest('Unbekannte Raumform.');
}

export function normalizeEquipment(list) {
  if (list === undefined || list === null) return '[]';
  const items = (Array.isArray(list) ? list : String(list).split(','))
    .map((s) => String(s).trim())
    .filter(Boolean);
  const unique = [...new Set(items)];
  if (unique.length > 30) throw badRequest('Zu viele Ausstattungsmerkmale.');
  for (const item of unique) if (item.length > 40) throw badRequest(`Ausstattung zu lang: ${item}`);
  return JSON.stringify(unique);
}

function parseJson(value, fallback) {
  try {
    return value ? JSON.parse(value) : fallback;
  } catch {
    return fallback;
  }
}

export function roomToApi(r) {
  return {
    id: r.id,
    floorId: r.floor_id,
    name: r.name,
    kind: r.kind,
    capacity: r.capacity,
    equipment: parseJson(r.equipment, []),
    description: r.description,
    shape: parseJson(r.shape, null),
    bookable: Boolean(r.bookable),
  };
}

export function floorToApi(f) {
  return {
    id: f.id,
    buildingId: f.building_id,
    name: f.name,
    level: f.level,
    width: f.width,
    height: f.height,
    imageVersion: f.image_version,
    imageUrl: f.image_version ? `/api/floors/${f.id}/image?v=${f.image_version}` : null,
  };
}

export function buildingToApi(b) {
  return { id: b.id, name: b.name, address: b.address, sort: b.sort };
}

/** Gebäude → Etagen → Räume, inkl. Grundriss-Bilder und Raumformen. */
export class LayoutService {
  constructor(ctx) {
    this.ctx = ctx;
  }

  get db() {
    return this.ctx.db;
  }

  changed() {
    this.db.afterCommit(() => this.ctx.hub.broadcast('layout-changed', {}));
  }

  full() {
    return {
      buildings: this.db.all('SELECT * FROM buildings ORDER BY sort, name COLLATE NOCASE').map(buildingToApi),
      floors: this.db
        .all('SELECT id, building_id, name, level, width, height, image_version FROM floors ORDER BY building_id, level, name COLLATE NOCASE')
        .map(floorToApi),
      rooms: this.db.all('SELECT * FROM rooms ORDER BY floor_id, name COLLATE NOCASE').map(roomToApi),
    };
  }

  building(id) {
    const b = this.db.get('SELECT * FROM buildings WHERE id = ?', [toId(id)]);
    if (!b) throw notFound('Gebäude nicht gefunden.');
    return b;
  }

  floor(id) {
    const f = this.db.get('SELECT id, building_id, name, level, width, height, image_version FROM floors WHERE id = ?', [toId(id)]);
    if (!f) throw notFound('Etage nicht gefunden.');
    return f;
  }

  room(id) {
    const r = this.db.get('SELECT * FROM rooms WHERE id = ?', [toId(id)]);
    if (!r) throw notFound('Raum nicht gefunden.');
    return r;
  }

  // ------------------------------------------------------------------ Gebäude

  createBuilding(actor, input) {
    const name = reqString(input.name, 'Name', { max: 100 });
    const address = optString(input.address, 'Adresse', { max: 200 });
    const sort = toInt(input.sort, 'Sortierung', { min: -1000, max: 1000, def: 0 });
    return this.db.tx(() => {
      const r = this.db.run('INSERT INTO buildings (name, address, sort, created_at) VALUES (?, ?, ?, ?)', [
        name,
        address,
        sort,
        this.ctx.clock.now(),
      ]);
      this.ctx.audit(actor.id, 'building.create', name);
      this.changed();
      return buildingToApi(this.building(r.lastInsertRowid));
    });
  }

  updateBuilding(actor, id, input) {
    const b = this.building(id);
    const name = input.name !== undefined ? reqString(input.name, 'Name', { max: 100 }) : b.name;
    const address = input.address !== undefined ? optString(input.address, 'Adresse', { max: 200 }) : b.address;
    const sort = input.sort !== undefined ? toInt(input.sort, 'Sortierung', { min: -1000, max: 1000 }) : b.sort;
    return this.db.tx(() => {
      this.db.run('UPDATE buildings SET name = ?, address = ?, sort = ? WHERE id = ?', [name, address, sort, b.id]);
      this.ctx.audit(actor.id, 'building.update', name);
      this.changed();
      return buildingToApi(this.building(b.id));
    });
  }

  deleteBuilding(actor, id) {
    const b = this.building(id);
    return this.db.tx(() => {
      const roomIds = this.db
        .all('SELECT r.id FROM rooms r JOIN floors f ON f.id = r.floor_id WHERE f.building_id = ?', [b.id])
        .map((r) => r.id);
      const cancelled = this.ctx.bookings.cancelFutureInRooms(actor, roomIds, `Gebäude „${b.name}“ wurde entfernt`);
      this.db.run('DELETE FROM buildings WHERE id = ?', [b.id]);
      this.ctx.audit(actor.id, 'building.delete', `${b.name} (${cancelled} Buchungen storniert)`);
      this.changed();
      return { cancelledBookings: cancelled };
    });
  }

  // ------------------------------------------------------------------ Etagen

  createFloor(actor, input) {
    const building = this.building(input.buildingId);
    const name = reqString(input.name, 'Name', { max: 100 });
    const level = toInt(input.level, 'Ebene', { min: -20, max: 200, def: 0 });
    const width = toInt(input.width, 'Breite', { min: 100, max: 10000, def: 1200 });
    const height = toInt(input.height, 'Höhe', { min: 100, max: 10000, def: 800 });
    return this.db.tx(() => {
      const r = this.db.run('INSERT INTO floors (building_id, name, level, width, height, created_at) VALUES (?, ?, ?, ?, ?, ?)', [
        building.id,
        name,
        level,
        width,
        height,
        this.ctx.clock.now(),
      ]);
      this.ctx.audit(actor.id, 'floor.create', `${building.name}: ${name}`);
      this.changed();
      return floorToApi(this.floor(r.lastInsertRowid));
    });
  }

  updateFloor(actor, id, input) {
    const f = this.floor(id);
    const name = input.name !== undefined ? reqString(input.name, 'Name', { max: 100 }) : f.name;
    const level = input.level !== undefined ? toInt(input.level, 'Ebene', { min: -20, max: 200 }) : f.level;
    const width = input.width !== undefined ? toInt(input.width, 'Breite', { min: 100, max: 10000 }) : f.width;
    const height = input.height !== undefined ? toInt(input.height, 'Höhe', { min: 100, max: 10000 }) : f.height;
    return this.db.tx(() => {
      this.db.run('UPDATE floors SET name = ?, level = ?, width = ?, height = ? WHERE id = ?', [name, level, width, height, f.id]);
      this.ctx.audit(actor.id, 'floor.update', name);
      this.changed();
      return floorToApi(this.floor(f.id));
    });
  }

  deleteFloor(actor, id) {
    const f = this.floor(id);
    return this.db.tx(() => {
      const roomIds = this.db.all('SELECT id FROM rooms WHERE floor_id = ?', [f.id]).map((r) => r.id);
      const cancelled = this.ctx.bookings.cancelFutureInRooms(actor, roomIds, `Etage „${f.name}“ wurde entfernt`);
      this.db.run('DELETE FROM floors WHERE id = ?', [f.id]);
      this.ctx.audit(actor.id, 'floor.delete', `${f.name} (${cancelled} Buchungen storniert)`);
      this.changed();
      return { cancelledBookings: cancelled };
    });
  }

  setFloorImage(actor, id, buffer, { width, height } = {}) {
    const f = this.floor(id);
    if (!buffer?.length) throw badRequest('Es wurde keine Datei empfangen.');
    const mime = detectImage(buffer);
    if (!mime) throw badRequest('Bitte ein Bild hochladen (PNG, JPG, WebP, GIF oder SVG).');
    const w = width !== undefined && width !== '' ? toInt(width, 'Breite', { min: 100, max: 10000 }) : f.width;
    const h = height !== undefined && height !== '' ? toInt(height, 'Höhe', { min: 100, max: 10000 }) : f.height;
    return this.db.tx(() => {
      this.db.run(
        `INSERT INTO floor_images (floor_id, mime, data, updated_at) VALUES (?, ?, ?, ?)
         ON CONFLICT(floor_id) DO UPDATE SET mime = excluded.mime, data = excluded.data, updated_at = excluded.updated_at`,
        [f.id, mime, buffer, this.ctx.clock.now()],
      );
      this.db.run('UPDATE floors SET image_version = image_version + 1, width = ?, height = ? WHERE id = ?', [w, h, f.id]);
      this.ctx.audit(actor.id, 'floor.image', `${f.name}: Grundriss hochgeladen (${mime}, ${Math.round(buffer.length / 1024)} KB)`);
      this.changed();
      return floorToApi(this.floor(f.id));
    });
  }

  removeFloorImage(actor, id) {
    const f = this.floor(id);
    return this.db.tx(() => {
      this.db.run('DELETE FROM floor_images WHERE floor_id = ?', [f.id]);
      this.db.run('UPDATE floors SET image_version = 0 WHERE id = ?', [f.id]);
      this.ctx.audit(actor.id, 'floor.image', `${f.name}: Grundriss entfernt`);
      this.changed();
      return floorToApi(this.floor(f.id));
    });
  }

  floorImage(id) {
    return this.db.get('SELECT mime, data FROM floor_images WHERE floor_id = ?', [toId(id)]) || null;
  }

  // ------------------------------------------------------------------ Räume

  roomInput(input, floor, current = {}) {
    const has = (k) => input[k] !== undefined;
    const kind = has('kind') ? String(input.kind) : current.kind || 'room';
    if (!KINDS.includes(kind)) throw badRequest('Ungültiger Raumtyp.');
    return {
      name: has('name') ? reqString(input.name, 'Name', { max: 100 }) : current.name,
      kind,
      capacity: has('capacity') ? toInt(input.capacity, 'Kapazität', { min: 0, max: 10000 }) : (current.capacity ?? (kind === 'desk' ? 1 : 0)),
      equipment: has('equipment') ? normalizeEquipment(input.equipment) : (current.equipment ?? '[]'),
      description: has('description') ? optString(input.description, 'Beschreibung', { max: 2000 }) : (current.description ?? ''),
      shape: has('shape') ? normalizeShape(input.shape, floor) : (current.shape ?? null),
      bookable: has('bookable') ? toBool(input.bookable) : current.bookable !== undefined ? Boolean(current.bookable) : true,
    };
  }

  createRoom(actor, input) {
    const floor = this.floor(input.floorId);
    const v = this.roomInput(input, floor);
    if (!v.name) throw badRequest('Name fehlt.');
    const now = this.ctx.clock.now();
    return this.db.tx(() => {
      const r = this.db.run(
        `INSERT INTO rooms (floor_id, name, kind, capacity, equipment, description, shape, bookable, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [floor.id, v.name, v.kind, v.capacity, v.equipment, v.description, v.shape, v.bookable, now, now],
      );
      this.ctx.audit(actor.id, 'room.create', `${floor.name}: ${v.name}`);
      this.changed();
      return roomToApi(this.room(r.lastInsertRowid));
    });
  }

  updateRoom(actor, id, input) {
    const current = this.room(id);
    const floor = this.floor(input.floorId !== undefined ? input.floorId : current.floor_id);
    const v = this.roomInput(input, floor, current);
    return this.db.tx(() => {
      let cancelled = 0;
      if (current.kind !== 'area' && v.kind === 'area') {
        cancelled = this.ctx.bookings.cancelFutureInRooms(actor, [current.id], `„${current.name}“ ist nicht mehr buchbar`);
      }
      this.db.run(
        `UPDATE rooms SET floor_id = ?, name = ?, kind = ?, capacity = ?, equipment = ?, description = ?, shape = ?, bookable = ?, updated_at = ?
         WHERE id = ?`,
        [floor.id, v.name, v.kind, v.capacity, v.equipment, v.description, v.shape, v.bookable, this.ctx.clock.now(), current.id],
      );
      if (input.shape === undefined || Object.keys(input).some((k) => k !== 'shape')) {
        this.ctx.audit(actor.id, 'room.update', v.name + (cancelled ? ` (${cancelled} Buchungen storniert)` : ''));
      }
      this.changed();
      return roomToApi(this.room(current.id));
    });
  }

  deleteRoom(actor, id) {
    const room = this.room(id);
    return this.db.tx(() => {
      const cancelled = this.ctx.bookings.cancelFutureInRooms(actor, [room.id], `Raum „${room.name}“ wurde entfernt`);
      this.db.run('DELETE FROM rooms WHERE id = ?', [room.id]);
      this.ctx.audit(actor.id, 'room.delete', `${room.name} (${cancelled} Buchungen storniert)`);
      this.changed();
      return { cancelledBookings: cancelled };
    });
  }
}
