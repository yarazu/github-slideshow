/**
 * Daten-Backend der Web-Version auf claude.ai.
 *
 * Es setzt dieselbe API um wie der Node-Server (/api/…), nur dass alles im Browser läuft und
 * die gemeinsame, live synchronisierte Datenbank von claude.ai (`db`) nutzt. So bleiben alle
 * Ansichten identisch.
 *
 * Datenmodell (Pfade in der Datenbank):
 *   layout/main            Gebäude, Etagen, Räume (ein Dokument, nur Administration)
 *   settings/main          Einstellungen inkl. Administrations-Liste
 *   bookings/<id>          eine Buchung pro Dokument
 *   notifications/<id>     Benachrichtigungen (Empfänger: Feld `to`)
 *   watches/<id>           „Benachrichtigen, wenn frei“
 *   people/<userId>        wer den Raumplaner schon genutzt hat (für Auswahllisten)
 *   audit/<id>             Protokoll
 *   locks/<name>           kurze Sperren (Leases) gegen gleichzeitige Änderungen
 *   data/users/<id>/prefs  persönliche Einstellungen (privat)
 *
 * Schutz vor Doppelbuchungen: Es gibt keine Transaktionen. Deshalb holt jede Buchung zuerst
 * eine kurze Sperre auf den Raum (Lease), liest dann frisch alle Buchungen des Raums, prüft
 * und schreibt. Zusätzlich wird nach dem Schreiben nachkontrolliert; sollte sich trotzdem
 * etwas überschneiden (z. B. weil eine Sperre wegen Netzproblemen abgelaufen ist), gewinnt
 * nach einer festen Regel die früher angelegte Buchung – auf allen Geräten gleich.
 */
import { DEMO } from '../../../server/demo.js';
import { HttpError } from '../../../server/errors.js';
import { normalizeEquipment, normalizeShape } from '../../../server/layout.js';
import { DEFAULT_SETTINGS, normalizeSettings } from '../../../server/settings.js';
import { optString, reqString, toBool, toInt, toTimestamp } from '../../../server/validate.js';
import { expandRecurrence, formatDuration, formatRange, formatTime, isValidTimezone, parseDateKey } from '../../shared/time.js';
import { ApiError, bus, setBackend } from '../api.js';
import { state } from '../state.js';

const WINDOW_PAST_MS = 2 * 86400000;
const LOCK_TTL_MS = 8000;
const LOCK_WAIT_MS = 12000;
const NOTIFICATION_LIMIT = 60;
const KEEP_BOOKINGS_DAYS = 60;
const KEEP_NOTIFICATIONS_DAYS = 30;
const MAX_WATCHES = 20;
const HOLDER = `tab-${Math.random().toString(36).slice(2)}-${Date.now().toString(36)}`;

let db = null;
let user = null;
let assets = null;
let downloads = null;
let me = { id: null, name: '', email: null, isOwner: false, canEdit: false };
let canWrite = false;
let ready = null;
let live = null;
let online = true;
const startedAt = Date.now();

const cache = {
  settings: { ...DEFAULT_SETTINGS, timezone: 'Europe/Berlin', admin_ids: [] },
  layout: emptyLayout(),
  bookings: new Map(),
  notifications: [],
  people: new Map(),
  prefs: {},
};

// ====================================================================== Einstieg

export function installHosted() {
  state.hosted = true;
  state.hostedConnect = (handlers) => {
    live = handlers;
    handlers.onStatus?.(online);
    handlers.onUnread?.(unreadCount());
  };
  ready = init();
  setBackend(async (method, url, body, opts) => {
    await ready;
    try {
      return await route(method, url, body, opts);
    } catch (err) {
      throw toApiError(err);
    }
  });
}

async function init() {
  const claude = window.claude;
  if (!claude?.use) {
    throw new ApiError(503, { message: 'Der Raumplaner läuft hier nicht in claude.ai. Bitte öffne ihn über den claude.ai-Link.' });
  }
  [db, user, assets, downloads] = await Promise.all(['db', 'user', 'assets', 'downloads'].map((n) => claude.use(n).catch(() => null)));
  if (!db) {
    throw new ApiError(503, {
      message: 'Die gemeinsame Datenbank ist in dieser Ansicht nicht verfügbar. Bitte melde dich in claude.ai an und öffne den Raumplaner erneut.',
    });
  }
  if (user) {
    const v = await user.me();
    me = { id: v.id, name: v.name, email: v.email, isOwner: v.isOwner, canEdit: v.canEdit };
    const can = await user.can('data.write');
    canWrite = can === null ? Boolean(v.id) : can;
  }
  if (!me.id) canWrite = false;

  await Promise.all([
    subscribe(db.doc('settings/main'), (snap) => {
      cache.settings = { ...DEFAULT_SETTINGS, timezone: 'Europe/Berlin', admin_ids: [], ...(snap.exists ? snap.data() : {}) };
      if (state.config) {
        state.config = config();
        bus.emit('config-changed', {});
      }
    }),
    subscribe(db.doc('layout/main'), (snap) => {
      cache.layout = normalizeLayout(snap.exists ? snap.data() : null);
      state.layout = apiLayout();
      bus.emit('layout-changed', {});
    }),
    subscribe(db.collection('bookings').where('end', '>', startedAt - WINDOW_PAST_MS), (snap) => {
      const next = new Map();
      for (const d of snap.docs) next.set(d.id, { id: d.id, ...d.data() });
      cache.bookings = next;
      bus.emit('bookings-changed', {});
    }),
  ]);

  if (me.id) {
    subscribe(db.doc(`data/users/${me.id}/prefs`), (snap) => {
      cache.prefs = snap.exists ? { ...snap.data() } : {};
    });
    const seen = new Set();
    let first = true;
    subscribe(
      db.collection('notifications').where('to', '==', me.id).orderBy('createdAt', 'desc').limit(NOTIFICATION_LIMIT),
      async (snap) => {
        cache.notifications = snap.docs.map((d) => ({ id: d.id, ...d.data() }));
        const fresh = first ? [] : snap.docChanges().filter((c) => c.type === 'added' && !seen.has(c.doc.id) && (c.doc.data().createdAt || 0) >= startedAt - 5000);
        for (const c of snap.docChanges()) seen.add(c.doc.id);
        first = false;
        live?.onUnread?.(unreadCount());
        if (fresh.length) {
          const items = await apiNotifications(fresh.map((c) => ({ id: c.doc.id, ...c.doc.data() })));
          for (const n of items) live?.onNotification?.({ ...n, unreadCount: unreadCount() });
        }
      },
    );
  }
  subscribe(db.collection('people'), (snap) => {
    cache.people = new Map(snap.docs.map((d) => [d.id, { id: d.id, ...d.data() }]));
  });

  registerPresence().catch(() => {});
  setTimeout(() => housekeeping().catch(() => {}), 8000);
  setInterval(() => remindLoop().catch(() => {}), 30000);
  setTimeout(() => remindLoop().catch(() => {}), 3000);
}

/** Abonniert ein Dokument oder eine Abfrage; das Promise erfüllt sich beim ersten Ergebnis (spätestens nach 10 s). */
function subscribe(target, onData) {
  return new Promise((resolve) => {
    let settled = false;
    const done = () => {
      if (!settled) {
        settled = true;
        resolve();
      }
    };
    const timer = setTimeout(() => {
      setOnline(false);
      done();
    }, 10000);
    target.onSnapshot(
      (snap) => {
        try {
          onData(snap);
        } catch (err) {
          console.error('[raumplaner] Fehler beim Verarbeiten neuer Daten', err);
        }
        if (!snap.metadata?.fromCache) {
          clearTimeout(timer);
          setOnline(true);
        }
        done();
      },
      (err) => {
        console.warn('[raumplaner] Live-Verbindung beendet', err);
        clearTimeout(timer);
        setOnline(false);
        done();
      },
    );
  });
}

function setOnline(value) {
  if (online === value) return;
  online = value;
  live?.onStatus?.(value);
}

// ====================================================================== Hilfen

const clone = (o) => JSON.parse(JSON.stringify(o));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const tz = () => cache.settings.timezone || 'Europe/Berlin';
const fail = (status, message, extra) => new ApiError(status, { message, ...(extra || {}) });
const isAdmin = () => Boolean(me.isOwner || (me.id && (cache.settings.admin_ids || []).includes(me.id)));

function toApiError(err) {
  if (err instanceof ApiError) return err;
  if (err instanceof HttpError) return new ApiError(err.status, { message: err.message, ...(err.extra || {}) });
  const code = err?.code;
  const messages = {
    invalid_argument: 'Dafür fehlt dir in claude.ai die Berechtigung (Schreibzugriff). Bitte wende dich an die Person, die den Raumplaner geteilt hat.',
    not_granted: 'Dafür fehlt dir in claude.ai die Berechtigung.',
    quota_exceeded: 'Der Speicher des Raumplaners ist voll. Bitte alte Daten aufräumen oder exportieren.',
    resource_exhausted: 'Gerade sind es zu viele Anfragen. Bitte versuche es in ein paar Sekunden noch einmal.',
    rate_limited: 'Gerade sind es zu viele Anfragen. Bitte versuche es in ein paar Sekunden noch einmal.',
    unavailable: 'Die Verbindung zu claude.ai ist gerade gestört. Bitte versuche es gleich noch einmal.',
    store_unavailable: 'Die Verbindung zu claude.ai ist gerade gestört. Bitte versuche es gleich noch einmal.',
    revoked: 'Dein Zugriff auf den Raumplaner wurde beendet.',
    too_large: 'Die Datei ist zu groß (Bilder bis 20 MB, SVG bis 2 MB).',
    unsupported_type: 'Dieses Dateiformat wird nicht unterstützt. Bitte PNG, JPG, WebP, GIF oder SVG verwenden.',
    declined: 'Der Download wurde abgebrochen.',
  };
  if (code && messages[code]) return new ApiError(code === 'invalid_argument' || code === 'not_granted' ? 403 : 503, { message: messages[code] });
  console.error('[raumplaner] Unerwarteter Fehler', err);
  return new ApiError(500, { message: 'Das hat nicht geklappt. Bitte versuche es erneut.' });
}

function requireWrite() {
  if (!me.id) throw fail(401, 'Bitte melde dich in claude.ai an, um zu buchen.');
  if (!canWrite) throw fail(403, 'Du kannst den Raumplaner nur ansehen. Zum Buchen braucht es Schreibzugriff – frag die Person, die ihn geteilt hat.');
}

function requireAdmin() {
  requireWrite();
  if (!isAdmin()) throw fail(403, 'Nur für die Administration.');
}

/** Führt Aufgaben mit demselben Schlüssel in diesem Tab nacheinander aus. */
const chains = new Map();
function serial(key, fn) {
  const prev = chains.get(key) || Promise.resolve();
  const run = prev.catch(() => {}).then(fn);
  chains.set(
    key,
    run.catch(() => {}),
  );
  return run;
}

/** Kurze Sperre (Lease) über alle Geräte hinweg – plus Reihenfolge innerhalb dieses Tabs. */
function withLock(name, fn, busyMessage) {
  return serial(`lock:${name}`, async () => {
    const ref = db.doc(`locks/${name}`);
    const deadline = Date.now() + LOCK_WAIT_MS;
    for (;;) {
      const r = await ref.acquire({ holder: HOLDER, ttlMs: LOCK_TTL_MS });
      if (r.acquired) break;
      if (Date.now() > deadline) throw fail(409, busyMessage || 'Gerade ändert jemand anderes dieselben Daten. Bitte versuche es gleich noch einmal.');
      await sleep(250 + Math.random() * 450);
    }
    try {
      return await fn();
    } finally {
      // Sperre zügig wieder freigeben (Verlängerung auf 1 s)
      ref.acquire({ holder: HOLDER, ttlMs: 1000 }).catch(() => {});
    }
  });
}

async function inBatches(items, size, fn) {
  const out = [];
  for (let i = 0; i < items.length; i += size) out.push(...(await Promise.all(items.slice(i, i + size).map(fn))));
  return out;
}

async function audit(action, details) {
  if (!me.id || !canWrite) return;
  try {
    await db.collection('audit').add({ actorId: me.id, action, details: String(details).slice(0, 500), at: Date.now() });
  } catch {
    /* Protokoll ist nicht kritisch */
  }
}

// ---------------------------------------------------------------------- Personen

async function profilesFor(ids) {
  const unique = [...new Set(ids.filter(Boolean))];
  if (!user || !unique.length) return {};
  try {
    return await user.profiles(unique);
  } catch {
    return {};
  }
}

function nameFrom(ps, id) {
  if (!id) return 'Unbekannte Person';
  if (id === me.id && !ps[id]?.name) return me.name || 'Du';
  return ps[id]?.name || 'Unbekannte Person';
}

const emailFrom = (ps, id) => ps[id]?.email || (id === me.id ? me.email : null) || '';

async function registerPresence() {
  if (!me.id || !canWrite) return;
  const ref = db.doc(`people/${me.id}`);
  const snap = await ref.get();
  const now = Date.now();
  const cur = snap.exists ? snap.data() : null;
  if (cur && now - (cur.lastSeen || 0) < 12 * 3600000) return;
  await ref.set({ firstSeen: cur?.firstSeen || now, lastSeen: now });
}

// ---------------------------------------------------------------------- Layout

function emptyLayout() {
  return { nextId: 1, buildings: [], floors: [], rooms: [] };
}

function normalizeLayout(data) {
  const l = { ...emptyLayout(), ...(data ? clone(data) : {}) };
  l.buildings = Array.isArray(l.buildings) ? l.buildings : [];
  l.floors = Array.isArray(l.floors) ? l.floors : [];
  l.rooms = Array.isArray(l.rooms) ? l.rooms : [];
  const maxId = Math.max(0, ...l.buildings.map((x) => x.id), ...l.floors.map((x) => x.id), ...l.rooms.map((x) => x.id));
  l.nextId = Math.max(Number(l.nextId) || 1, maxId + 1);
  return l;
}

function apiFloor(f) {
  return {
    id: f.id,
    buildingId: f.buildingId,
    name: f.name,
    level: f.level ?? 0,
    width: f.width ?? 1200,
    height: f.height ?? 800,
    imageVersion: f.imageAssetId ? f.imageVersion || 1 : 0,
    imageUrl: f.imageAssetId ? `/_blob/${f.imageAssetId}` : null,
  };
}

function apiLayout() {
  const l = cache.layout;
  return {
    buildings: [...l.buildings].sort((a, b) => (a.sort ?? 0) - (b.sort ?? 0) || a.name.localeCompare(b.name, 'de')).map((b) => ({ id: b.id, name: b.name, address: b.address || '', sort: b.sort ?? 0 })),
    floors: [...l.floors].sort((a, b) => a.buildingId - b.buildingId || (a.level ?? 0) - (b.level ?? 0)).map(apiFloor),
    rooms: [...l.rooms].sort((a, b) => a.floorId - b.floorId || a.name.localeCompare(b.name, 'de', { numeric: true })).map((r) => ({
      id: r.id,
      floorId: r.floorId,
      name: r.name,
      kind: r.kind || 'room',
      capacity: r.capacity ?? 0,
      equipment: r.equipment || [],
      description: r.description || '',
      shape: r.shape || null,
      bookable: r.bookable !== false,
    })),
  };
}

const roomOf = (id) => cache.layout.rooms.find((r) => r.id === Number(id));
const floorOf = (id) => cache.layout.floors.find((f) => f.id === Number(id));
const buildingOf = (id) => cache.layout.buildings.find((b) => b.id === Number(id));

function placeOf(roomId) {
  const room = roomOf(roomId);
  const floor = room && floorOf(room.floorId);
  const building = floor && buildingOf(floor.buildingId);
  return [room?.name, floor?.name, building?.name].filter(Boolean).join(' · ') || 'Gelöschter Raum';
}

/** Liest das Layout frisch, ändert es unter einer Sperre und schreibt es zurück. */
async function mutateLayout(fn, auditAction, auditText) {
  requireAdmin();
  return withLock('layout', async () => {
    const snap = await db.doc('layout/main').get();
    const cur = normalizeLayout(snap.exists ? snap.data() : null);
    const result = await fn(cur);
    cur.updatedAt = Date.now();
    await db.doc('layout/main').set(cur);
    cache.layout = cur;
    state.layout = apiLayout();
    bus.emit('layout-changed', {});
    if (auditAction) audit(auditAction, typeof auditText === 'function' ? auditText(result) : auditText);
    return result;
  }, 'Gerade ändert jemand anderes die Raumpläne. Bitte versuche es gleich noch einmal.');
}

const findOr404 = (list, id, label) => {
  const item = list.find((x) => x.id === Number(id));
  if (!item) throw fail(404, `${label} nicht gefunden.`);
  return item;
};

function roomValues(input, floor, current = {}) {
  const has = (k) => input[k] !== undefined;
  const kind = has('kind') ? String(input.kind) : current.kind || 'room';
  if (!['room', 'desk', 'area'].includes(kind)) throw fail(400, 'Ungültiger Raumtyp.');
  return {
    name: has('name') ? reqString(input.name, 'Name', { max: 100 }) : current.name,
    kind,
    capacity: has('capacity') ? toInt(input.capacity, 'Kapazität', { min: 0, max: 10000 }) : (current.capacity ?? (kind === 'desk' ? 1 : 0)),
    equipment: has('equipment') ? JSON.parse(normalizeEquipment(input.equipment)) : (current.equipment ?? []),
    description: has('description') ? optString(input.description, 'Beschreibung', { max: 1000 }) : (current.description ?? ''),
    shape: has('shape') ? JSON.parse(normalizeShape(input.shape, floor) ?? 'null') : (current.shape ?? null),
    bookable: has('bookable') ? toBool(input.bookable) : current.bookable !== false,
  };
}

// ---------------------------------------------------------------------- Buchungen: Darstellung

function bookingIds(b) {
  return [b.userId, ...(b.attendeeIds || []), b.cancelledBy];
}

function toApiBooking(b, ps) {
  const room = roomOf(b.roomId);
  const floor = room && floorOf(room.floorId);
  const building = floor && buildingOf(floor.buildingId);
  const attendeeIds = b.attendeeIds || [];
  return {
    id: b.id,
    type: b.type || 'booking',
    title: b.title,
    description: b.description || '',
    isPrivate: false,
    masked: false,
    start: b.start,
    end: b.end,
    status: b.status,
    seriesId: b.seriesId || null,
    cancelReason: b.cancelReason || null,
    room: { id: b.roomId, name: room?.name || 'Gelöschter Raum', kind: room?.kind || 'room', capacity: room?.capacity || 0 },
    floor: { id: floor?.id ?? null, name: floor?.name || '–' },
    building: { id: building?.id ?? null, name: building?.name || '–' },
    user: { id: b.userId, name: nameFrom(ps, b.userId), email: emailFrom(ps, b.userId) },
    attendees: attendeeIds.map((id) => ({ key: id, email: emailFrom(ps, id), name: nameFrom(ps, id) })),
    isOwner: b.userId === me.id,
    isAttendee: Boolean(me.id) && attendeeIds.includes(me.id),
    canEdit: Boolean(canWrite && (isAdmin() || b.userId === me.id) && b.status === 'confirmed' && b.end > Date.now()),
    createdAt: b.createdAt,
    updatedAt: b.updatedAt,
  };
}

async function apiBookings(list) {
  const ps = await profilesFor(list.flatMap(bookingIds));
  return list.map((b) => toApiBooking(b, ps));
}

const overlaps = (b, start, end) => b.start < end && b.end > start;
const confirmedInCache = () => [...cache.bookings.values()].filter((b) => b.status === 'confirmed');

/** Frischer Blick in die Datenbank (nicht aus dem Zwischenspeicher) – für alle Prüfungen vor dem Schreiben. */
async function freshRoomBookings(roomId, from, to) {
  const snap = await db.collection('bookings').where('roomId', '==', roomId).where('end', '>', from).get();
  return snap.docs.map((d) => ({ id: d.id, ...d.data() })).filter((b) => b.status === 'confirmed' && b.start < to);
}

async function loadBooking(id) {
  const cached = cache.bookings.get(String(id));
  if (cached) return { ...cached };
  const snap = await db.doc(`bookings/${String(id)}`).get();
  if (!snap.exists) throw fail(404, 'Buchung nicht gefunden.');
  return { id: snap.id, ...snap.data() };
}

async function freshBooking(id) {
  const snap = await db.doc(`bookings/${String(id)}`).get();
  if (!snap.exists) throw fail(404, 'Buchung nicht gefunden.');
  return { id: snap.id, ...snap.data() };
}

// ---------------------------------------------------------------------- Buchungen: Regeln

function bookableRoom(roomId) {
  const room = roomOf(roomId);
  if (!room) throw fail(404, 'Der Raum existiert nicht (mehr).');
  if (room.kind === 'area') throw fail(400, 'Dieser Bereich kann nicht gebucht werden.');
  return room;
}

function checkTimes(start, end, { allowStartedAt = null } = {}) {
  const s = cache.settings;
  const now = Date.now();
  if (!(end > start)) throw fail(400, 'Das Ende muss nach dem Beginn liegen.');
  if (end - start < 5 * 60000) throw fail(400, 'Eine Buchung muss mindestens 5 Minuten dauern.');
  if (end <= now) throw fail(400, 'Der Zeitraum liegt in der Vergangenheit.');
  const grace = Math.max(5, s.slot_minutes) * 60000;
  if (start < now - grace && start !== allowStartedAt) throw fail(400, 'Der Beginn liegt in der Vergangenheit.');
  if (!isAdmin()) {
    if (end - start > s.max_booking_minutes * 60000) throw fail(400, `Eine Buchung darf höchstens ${formatDuration(s.max_booking_minutes * 60000)} dauern.`);
    if (start > now + s.max_days_ahead * 86400000) throw fail(400, `Buchungen sind höchstens ${s.max_days_ahead} Tage im Voraus möglich.`);
  }
}

function normalizeAttendeeIds(list, bookerId) {
  if (!list) return [];
  const items = Array.isArray(list) ? list : String(list).split(',');
  const out = [];
  for (const raw of items) {
    const id = String(raw ?? '').trim();
    if (!id || id === bookerId || out.includes(id)) continue;
    if (!/^[A-Za-z0-9_\-.~:@+]{1,200}$/.test(id)) throw fail(400, 'Ungültige Person bei den Teilnehmenden.');
    out.push(id);
  }
  if (out.length > 30) throw fail(400, 'Maximal 30 Teilnehmende pro Buchung.');
  return out;
}

async function conflictPayload(groups) {
  const ps = await profilesFor(groups.flatMap((g) => g.conflicts.flatMap(bookingIds)));
  return groups.map((g) => ({ start: g.start, end: g.end, bookings: g.conflicts.map((b) => toApiBooking(b, ps)) }));
}

/** Feste Gewinnerregel für den seltenen Fall gleichzeitiger Buchungen: früher angelegt gewinnt. */
const beats = (a, b) => (a.createdAt ?? 0) < (b.createdAt ?? 0) || ((a.createdAt ?? 0) === (b.createdAt ?? 0) && a.id < b.id);

/** Nachkontrolle nach dem Schreiben. Gibt die eigenen Buchungen zurück, die verloren haben (und storniert sie). */
async function verifyNoOverlap(roomId, mine) {
  if (!mine.length) return [];
  const from = Math.min(...mine.map((b) => b.start));
  const to = Math.max(...mine.map((b) => b.end));
  const fresh = await freshRoomBookings(roomId, from, to);
  const ids = new Set(mine.map((b) => b.id));
  const lost = mine.filter((b) => fresh.some((o) => !ids.has(o.id) && overlaps(o, b.start, b.end) && beats(o, b)));
  await inBatches(lost, 6, (b) =>
    db.doc(`bookings/${b.id}`).update({ status: 'cancelled', cancelReason: 'Gleichzeitig gebucht – die andere Buchung war schneller', updatedAt: Date.now() }),
  );
  return lost;
}

// ---------------------------------------------------------------------- Benachrichtigungen

async function notify(to, data) {
  if (!to || to === me.id) return;
  try {
    await db.collection('notifications').add({ to, actorId: me.id, createdAt: Date.now(), read: false, ...data });
  } catch (err) {
    console.warn('[raumplaner] Benachrichtigung konnte nicht gespeichert werden', err);
  }
}

function bookingSummary(b, count = 1) {
  return { bookingId: b.id, roomId: b.roomId, place: placeOf(b.roomId), title: b.title, start: b.start, end: b.end, count };
}

async function notifyCreated(bookings) {
  const b = bookings[0];
  if (!b || b.type !== 'booking') return;
  await Promise.all((b.attendeeIds || []).map((to) => notify(to, { type: 'invite', ...bookingSummary(b, bookings.length) })));
}

async function notifyCancelled(rows, reason) {
  const groups = new Map();
  for (const r of rows) {
    if (r.type !== 'booking') continue;
    const key = r.seriesId ? `s:${r.seriesId}` : `b:${r.id}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(r);
  }
  for (const group of groups.values()) {
    group.sort((a, b) => a.start - b.start);
    const b = group[0];
    const recipients = new Set([b.userId, ...(b.attendeeIds || [])]);
    recipients.delete(me.id);
    await Promise.all([...recipients].map((to) => notify(to, { type: 'cancelled', reason: reason || null, ownBooking: to === b.userId, ...bookingSummary(b, group.length) })));
  }
}

async function notifyUpdated(after, before, added, removed) {
  if (after.type !== 'booking') return;
  const changes = [];
  if (before.start !== after.start || before.end !== after.end) changes.push({ kind: 'time', from: [before.start, before.end], to: [after.start, after.end] });
  if (before.roomId !== after.roomId) changes.push({ kind: 'room', from: placeOf(before.roomId), to: placeOf(after.roomId) });
  if (before.title !== after.title) changes.push({ kind: 'title', from: before.title, to: after.title });
  const significant = changes.length > 0 || (before.description || '') !== (after.description || '');
  const jobs = [];
  for (const to of after.attendeeIds || []) {
    if (added.includes(to)) jobs.push(notify(to, { type: 'invite', ...bookingSummary(after) }));
    else if (significant) jobs.push(notify(to, { type: 'updated', changes, ...bookingSummary(after) }));
  }
  if (significant && after.userId !== me.id) jobs.push(notify(after.userId, { type: 'updated', changes, ownBooking: true, ...bookingSummary(after) }));
  for (const to of removed) jobs.push(notify(to, { type: 'removed', ...bookingSummary(before) }));
  await Promise.all(jobs);
}

function describeChanges(changes = []) {
  return (
    changes
      .map((c) => {
        if (c.kind === 'time') return `Neue Zeit: ${formatRange(c.to[0], c.to[1], tz())} (vorher: ${formatRange(c.from[0], c.from[1], tz())})`;
        if (c.kind === 'room') return `Neuer Raum: ${c.to} (vorher: ${c.from})`;
        if (c.kind === 'title') return `Neuer Titel: ${c.to} (vorher: ${c.from})`;
        return '';
      })
      .filter(Boolean)
      .join(' · ') || 'Details wurden aktualisiert.'
  );
}

function notificationText(n, ps) {
  const actor = nameFrom(ps, n.actorId);
  const when = n.start ? (n.count > 1 ? `${n.count} Termine ab ${formatRange(n.start, n.end, tz())}` : formatRange(n.start, n.end, tz())) : '';
  const place = n.place || (n.roomId ? placeOf(n.roomId) : '');
  const bookingLink = n.bookingId ? `#/buchungen?id=${n.bookingId}` : null;
  switch (n.type) {
    case 'invite':
      return { title: `Einladung: ${n.title}`, body: `${actor} hat dich eingeladen – ${when} · ${place}`, link: bookingLink };
    case 'updated':
      return { title: n.ownBooking ? `Deine Buchung wurde geändert: ${n.title}` : `Termin geändert: ${n.title}`, body: `${actor}: ${describeChanges(n.changes)}`, link: bookingLink };
    case 'cancelled':
      return {
        title: n.ownBooking ? `Deine Buchung wurde storniert: ${n.title}` : `Abgesagt: ${n.title}`,
        body: `${when} · ${place} (durch ${actor}).${n.reason ? ` Grund: ${n.reason}.` : ''}`,
        link: null,
      };
    case 'removed':
      return { title: `Ausgeladen: ${n.title}`, body: `${actor} hat dich aus dem Termin am ${when} entfernt.`, link: null };
    case 'reminder': {
      const minutes = Math.max(0, Math.round((n.start - Date.now()) / 60000));
      const starts = n.start <= Date.now() ? 'hat begonnen' : minutes <= 1 ? 'beginnt jetzt' : `beginnt um ${formatTime(n.start, tz())} Uhr`;
      return { title: `Erinnerung: ${n.title} ${starts}`, body: `${when} · ${place}`, link: bookingLink };
    }
    case 'watch': {
      const roomName = roomOf(n.roomId)?.name || 'Der Raum';
      return {
        title: `Raum frei: ${roomName}`,
        body: `${when} ist ${roomName} jetzt frei – schnell buchen, bevor es jemand anderes tut.`,
        link: `#/buchen?room=${n.roomId}&start=${n.start}&end=${n.end}`,
      };
    }
    case 'test':
      return { title: 'Test-Benachrichtigung', body: 'Wenn du das liest, funktionieren deine Benachrichtigungen.', link: '#/benachrichtigungen' };
    default:
      return { title: n.title || 'Benachrichtigung', body: '', link: null };
  }
}

async function apiNotifications(list) {
  const ps = await profilesFor(list.map((n) => n.actorId));
  return list.map((n) => ({
    id: n.id,
    type: n.type,
    ...notificationText(n, ps),
    bookingId: n.bookingId || null,
    createdAt: n.createdAt,
    read: Boolean(n.read),
  }));
}

const unreadCount = () => cache.notifications.filter((n) => !n.read).length;

/** „Benachrichtigen, wenn frei“: prüft nach einer Freigabe die Vormerkungen für den Raum. */
async function checkWatches(roomId, from, to) {
  try {
    const now = Date.now();
    const snap = await db.collection('watches').where('roomId', '==', roomId).where('end', '>', now).get();
    const candidates = snap.docs.map((d) => ({ id: d.id, ...d.data() })).filter((w) => overlaps(w, from, to));
    if (!candidates.length) return;
    const fresh = await freshRoomBookings(roomId, Math.min(...candidates.map((w) => w.start)), Math.max(...candidates.map((w) => w.end)));
    for (const w of candidates) {
      if (fresh.some((b) => overlaps(b, Math.max(w.start, now), w.end))) continue;
      await db.doc(`watches/${w.id}`).delete();
      if (w.userId === me.id) {
        await db.collection('notifications').add({ to: me.id, actorId: me.id, type: 'watch', roomId, start: w.start, end: w.end, createdAt: Date.now(), read: false });
      } else {
        await notify(w.userId, { type: 'watch', roomId, start: w.start, end: w.end });
      }
    }
  } catch (err) {
    console.warn('[raumplaner] Raum-Wünsche konnten nicht geprüft werden', err);
  }
}

// ---------------------------------------------------------------------- Erinnerungen & Aufräumen

async function remindLoop() {
  if (!me.id || !canWrite) return;
  const minutes = cache.prefs.reminderMinutes ?? cache.settings.default_reminder_minutes;
  if (!minutes) return;
  const now = Date.now();
  for (const b of confirmedInCache()) {
    if (b.type !== 'booking' || b.start <= now || b.start > now + 86400000) continue;
    if (b.userId !== me.id && !(b.attendeeIds || []).includes(me.id)) continue;
    const remindAt = b.start - minutes * 60000;
    if (remindAt > now || remindAt < (b.timeChangedAt ?? b.createdAt ?? 0)) continue;
    const id = `rem-${b.id}-${b.start}-${me.id}`.replace(/[^A-Za-z0-9_\-.~:@+]/g, '_');
    if (cache.notifications.some((n) => n.id === id)) continue;
    await db.doc(`notifications/${id}`).set({ to: me.id, actorId: me.id, type: 'reminder', ...bookingSummary(b), createdAt: now, read: false });
  }
}

async function housekeeping() {
  if (!isAdmin() || !canWrite) return;
  const now = Date.now();
  const jobs = [
    ['bookings', db.collection('bookings').where('end', '<', now - KEEP_BOOKINGS_DAYS * 86400000).limit(100)],
    ['notifications', db.collection('notifications').where('createdAt', '<', now - KEEP_NOTIFICATIONS_DAYS * 86400000).limit(200)],
    ['watches', db.collection('watches').where('end', '<', now).limit(100)],
    ['audit', db.collection('audit').where('at', '<', now - 180 * 86400000).limit(200)],
  ];
  for (const [collection, query] of jobs) {
    const snap = await query.get();
    await inBatches(snap.docs, 5, (d) => db.doc(`${collection}/${d.id}`).delete());
  }
}

// ====================================================================== Routen

async function route(method, url, body, opts) {
  const u = new URL(url, 'https://raumplaner.invalid');
  const p = u.pathname;
  const q = u.searchParams;
  let m;
  const is = (verb, path) => method === verb && p === path;

  // ---- Konto & Konfiguration
  if (is('GET', '/api/config')) return config();
  if (is('GET', '/api/me')) return meApi();
  if (is('PUT', '/api/me')) return updatePrefs(body || {});
  if (is('POST', '/api/me/test-notification')) return testNotification();
  if (is('GET', '/api/users/directory')) return directory(q.get('q') || '');

  // ---- Layout
  if (is('GET', '/api/layout')) return apiLayout();
  if (is('POST', '/api/buildings')) return createBuilding(body || {});
  if ((m = /^\/api\/buildings\/(\d+)$/.exec(p))) {
    if (method === 'PUT') return updateBuilding(Number(m[1]), body || {});
    if (method === 'DELETE') return deleteBuilding(Number(m[1]));
  }
  if (is('POST', '/api/floors')) return createFloor(body || {});
  if ((m = /^\/api\/floors\/(\d+)\/image$/.exec(p))) {
    if (method === 'PUT') return setFloorImage(Number(m[1]), body, q);
    if (method === 'DELETE') return removeFloorImage(Number(m[1]));
  }
  if ((m = /^\/api\/floors\/(\d+)$/.exec(p))) {
    if (method === 'PUT') return updateFloor(Number(m[1]), body || {});
    if (method === 'DELETE') return deleteFloor(Number(m[1]));
  }
  if (is('POST', '/api/rooms')) return createRoom(body || {});
  if ((m = /^\/api\/rooms\/(\d+)$/.exec(p))) {
    if (method === 'PUT') return updateRoom(Number(m[1]), body || {});
    if (method === 'DELETE') return deleteRoom(Number(m[1]));
  }

  // ---- Buchungen
  if (is('GET', '/api/bookings')) return listBookings(q);
  if (is('POST', '/api/bookings')) return createBooking(body || {});
  if (is('GET', '/api/bookings/mine')) return mine(q.get('scope'));
  if (is('GET', '/api/availability')) return availability(q);
  if ((m = /^\/api\/bookings\/([^/]+)\/cancel$/.exec(p)) && method === 'POST') return cancelBooking(m[1], body || {});
  if ((m = /^\/api\/bookings\/([^/]+)\/end$/.exec(p)) && method === 'POST') return endBooking(m[1]);
  if ((m = /^\/api\/bookings\/([^/]+)$/.exec(p))) {
    if (method === 'GET') return (await apiBookings([await loadBooking(m[1])]))[0];
    if (method === 'PUT') return updateBooking(m[1], body || {});
  }

  // ---- Raum-Wünsche
  if (is('GET', '/api/watches')) return listWatches();
  if (is('POST', '/api/watches')) return createWatch(body || {});
  if ((m = /^\/api\/watches\/([^/]+)$/.exec(p)) && method === 'DELETE') return deleteWatch(m[1]);

  // ---- Benachrichtigungen
  if (is('GET', '/api/notifications')) {
    const limit = Math.min(Number(q.get('limit')) || 50, NOTIFICATION_LIMIT);
    return { items: await apiNotifications(cache.notifications.slice(0, limit)), unreadCount: unreadCount() };
  }
  if (is('POST', '/api/notifications/read')) return markRead(body || {});

  // ---- Verwaltung
  if (p.startsWith('/api/admin/')) {
    requireAdmin();
    if (is('GET', '/api/admin/settings')) return { ...cache.settings };
    if (is('PUT', '/api/admin/settings')) return updateSettings(body || {});
    if (is('GET', '/api/admin/audit')) return auditList(Number(q.get('limit')) || 200);
    if (is('POST', '/api/admin/demo')) return loadDemoLayout();
    if (is('GET', '/api/admin/people')) return peopleList();
    if ((m = /^\/api\/admin\/people\/([^/]+)$/.exec(p)) && method === 'PUT') return setAdmin(decodeURIComponent(m[1]), body || {});
    if (is('GET', '/api/admin/system')) return systemInfo();
    if (is('POST', '/api/admin/export')) return exportAll();
  }
  void opts;
  throw fail(404, 'Diese Funktion gibt es in der Web-Version nicht.');
}

// ---------------------------------------------------------------------- Konto

function config() {
  const s = cache.settings;
  return {
    hosted: true,
    orgName: s.org_name,
    timezone: tz(),
    dayStartHour: s.day_start_hour,
    dayEndHour: s.day_end_hour,
    slotMinutes: s.slot_minutes,
    maxBookingMinutes: s.max_booking_minutes,
    maxDaysAhead: s.max_days_ahead,
    allowRegistration: false,
    allowedEmailDomains: '',
    equipmentOptions: s.equipment_options,
    defaultReminderMinutes: s.default_reminder_minutes,
    mailEnabled: false,
    needsSetup: false,
    loggedIn: Boolean(me.id),
    canWrite,
    isOwner: Boolean(me.isOwner),
    version: 'web',
  };
}

function meApi() {
  return {
    user: {
      id: me.id,
      email: me.email || '',
      name: me.name || 'Du',
      role: isAdmin() ? 'admin' : 'user',
      active: true,
      notifyEmail: false,
      reminderMinutes: cache.prefs.reminderMinutes ?? cache.settings.default_reminder_minutes,
    },
    calendarUrl: '',
    unreadCount: unreadCount(),
  };
}

async function updatePrefs(input) {
  if (!me.id) throw fail(401, 'Bitte melde dich in claude.ai an.');
  if (input.reminderMinutes !== undefined) {
    const v = toInt(input.reminderMinutes, 'Erinnerung', { min: 0, max: 1440 });
    if (![0, 5, 10, 15, 30, 60, 120, 1440].includes(v)) throw fail(400, 'Ungültige Erinnerungszeit.');
    cache.prefs = { ...cache.prefs, reminderMinutes: v };
    await db.doc(`data/users/${me.id}/prefs`).set(cache.prefs);
  }
  return meApi();
}

async function testNotification() {
  requireWrite();
  await db.collection('notifications').add({ to: me.id, actorId: me.id, type: 'test', createdAt: Date.now(), read: false });
  return { inApp: true, email: false };
}

async function directory(query) {
  const ids = new Set(cache.people.keys());
  let hits = [];
  if (user) {
    try {
      hits = await user.search(query);
    } catch {
      hits = [];
    }
  }
  for (const hit of hits) ids.add(hit.id);
  const ps = await profilesFor([...ids]);
  const out = [];
  for (const id of ids) {
    if (id === me.id) continue;
    const p = ps[id];
    if (!p?.name) continue;
    if (query && !`${p.name} ${p.email || ''}`.toLowerCase().includes(query.toLowerCase())) continue;
    out.push({ id, name: p.name, email: p.email || '' });
  }
  return out.sort((a, b) => a.name.localeCompare(b.name, 'de'));
}

// ---------------------------------------------------------------------- Layout-Änderungen

function createBuilding(input) {
  const name = reqString(input.name, 'Name', { max: 100 });
  const address = optString(input.address, 'Adresse', { max: 200 });
  return mutateLayout(
    (l) => {
      const b = { id: l.nextId++, name, address, sort: Number(input.sort) || 0 };
      l.buildings.push(b);
      return { ...b };
    },
    'building.create',
    name,
  );
}

function updateBuilding(id, input) {
  return mutateLayout(
    (l) => {
      const b = findOr404(l.buildings, id, 'Gebäude');
      if (input.name !== undefined) b.name = reqString(input.name, 'Name', { max: 100 });
      if (input.address !== undefined) b.address = optString(input.address, 'Adresse', { max: 200 });
      if (input.sort !== undefined) b.sort = toInt(input.sort, 'Sortierung', { min: -1000, max: 1000 });
      return { ...b };
    },
    'building.update',
    (b) => b.name,
  );
}

/** Vor dem Entfernen oder Umwidmen von Räumen: zukünftige Buchungen stornieren, Vormerkungen löschen. */
async function cancelFutureInRooms(roomIds, reason) {
  if (!roomIds.length) return 0;
  const now = Date.now();
  const rows = [];
  for (const roomId of roomIds) {
    rows.push(...(await freshRoomBookings(roomId, now, Infinity)));
    const watches = await db.collection('watches').where('roomId', '==', roomId).get();
    await inBatches(watches.docs, 5, (d) => db.doc(`watches/${d.id}`).delete());
  }
  await cancelRows(rows, reason, { checkFreed: false });
  return rows.length;
}

async function deleteBuilding(id) {
  requireAdmin();
  const b = findOr404(cache.layout.buildings, id, 'Gebäude');
  const floorIds = cache.layout.floors.filter((f) => f.buildingId === id).map((f) => f.id);
  const roomIds = cache.layout.rooms.filter((r) => floorIds.includes(r.floorId)).map((r) => r.id);
  const cancelled = await cancelFutureInRooms(roomIds, `Gebäude „${b.name}“ wurde entfernt`);
  const assetIds = cache.layout.floors.filter((f) => floorIds.includes(f.id) && f.imageAssetId).map((f) => f.imageAssetId);
  await mutateLayout(
    (l) => {
      l.buildings = l.buildings.filter((x) => x.id !== id);
      l.floors = l.floors.filter((f) => f.buildingId !== id);
      l.rooms = l.rooms.filter((r) => !floorIds.includes(r.floorId));
    },
    'building.delete',
    `${b.name} (${cancelled} Buchungen storniert)`,
  );
  if (assets) for (const a of assetIds) assets.delete(a).catch(() => {});
  return { cancelledBookings: cancelled };
}

function createFloor(input) {
  const name = reqString(input.name, 'Name', { max: 100 });
  return mutateLayout(
    (l) => {
      findOr404(l.buildings, input.buildingId, 'Gebäude');
      const f = {
        id: l.nextId++,
        buildingId: Number(input.buildingId),
        name,
        level: toInt(input.level, 'Ebene', { min: -20, max: 200, def: 0 }),
        width: toInt(input.width, 'Breite', { min: 100, max: 10000, def: 1200 }),
        height: toInt(input.height, 'Höhe', { min: 100, max: 10000, def: 800 }),
        imageAssetId: null,
      };
      l.floors.push(f);
      return apiFloor(f);
    },
    'floor.create',
    name,
  );
}

function updateFloor(id, input) {
  return mutateLayout(
    (l) => {
      const f = findOr404(l.floors, id, 'Etage');
      if (input.name !== undefined) f.name = reqString(input.name, 'Name', { max: 100 });
      if (input.level !== undefined) f.level = toInt(input.level, 'Ebene', { min: -20, max: 200 });
      if (input.width !== undefined) f.width = toInt(input.width, 'Breite', { min: 100, max: 10000 });
      if (input.height !== undefined) f.height = toInt(input.height, 'Höhe', { min: 100, max: 10000 });
      return apiFloor(f);
    },
    'floor.update',
    (f) => f.name,
  );
}

async function deleteFloor(id) {
  requireAdmin();
  const f = findOr404(cache.layout.floors, id, 'Etage');
  const roomIds = cache.layout.rooms.filter((r) => r.floorId === id).map((r) => r.id);
  const cancelled = await cancelFutureInRooms(roomIds, `Etage „${f.name}“ wurde entfernt`);
  await mutateLayout(
    (l) => {
      l.floors = l.floors.filter((x) => x.id !== id);
      l.rooms = l.rooms.filter((r) => r.floorId !== id);
    },
    'floor.delete',
    `${f.name} (${cancelled} Buchungen storniert)`,
  );
  if (assets && f.imageAssetId) assets.delete(f.imageAssetId).catch(() => {});
  return { cancelledBookings: cancelled };
}

const IMAGE_TYPES = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', webp: 'image/webp', gif: 'image/gif', svg: 'image/svg+xml' };

async function setFloorImage(id, file, q) {
  requireAdmin();
  if (!assets) throw fail(403, 'Grundrisse hochladen kann nur, wer in claude.ai Bearbeitungszugriff (Editor) auf den Raumplaner hat.');
  if (!(file instanceof Blob) || !file.size) throw fail(400, 'Es wurde keine Datei empfangen.');
  const ext = String(file.name || '').split('.').pop().toLowerCase();
  const type = Object.values(IMAGE_TYPES).includes(file.type) ? file.type : IMAGE_TYPES[ext];
  if (!type) throw fail(400, 'Bitte ein Bild hochladen (PNG, JPG, WebP, GIF oder SVG).');
  const uploaded = await assets.upload(file, { type });
  let old = null;
  const floor = await mutateLayout(
    (l) => {
      const f = findOr404(l.floors, id, 'Etage');
      old = f.imageAssetId;
      f.imageAssetId = uploaded.id;
      f.imageVersion = (f.imageVersion || 0) + 1;
      if (q.get('width')) f.width = toInt(q.get('width'), 'Breite', { min: 100, max: 10000 });
      if (q.get('height')) f.height = toInt(q.get('height'), 'Höhe', { min: 100, max: 10000 });
      return apiFloor(f);
    },
    'floor.image',
    (f) => `${f.name}: Grundriss hochgeladen`,
  );
  if (old && old !== uploaded.id) assets.delete(old).catch(() => {});
  return floor;
}

async function removeFloorImage(id) {
  let old = null;
  const floor = await mutateLayout(
    (l) => {
      const f = findOr404(l.floors, id, 'Etage');
      old = f.imageAssetId;
      f.imageAssetId = null;
      return apiFloor(f);
    },
    'floor.image',
    (f) => `${f.name}: Grundriss entfernt`,
  );
  if (assets && old) assets.delete(old).catch(() => {});
  return floor;
}

function createRoom(input) {
  return mutateLayout(
    (l) => {
      const floor = findOr404(l.floors, input.floorId, 'Etage');
      const v = roomValues(input, floor);
      if (!v.name) throw fail(400, 'Name fehlt.');
      const room = { id: l.nextId++, floorId: floor.id, ...v };
      l.rooms.push(room);
      return clone(room);
    },
    'room.create',
    (r) => r.name,
  );
}

async function updateRoom(id, input) {
  requireAdmin();
  const current = findOr404(cache.layout.rooms, id, 'Raum');
  let cancelled = 0;
  if (current.kind !== 'area' && input.kind === 'area') cancelled = await cancelFutureInRooms([id], `„${current.name}“ ist nicht mehr buchbar`);
  const onlyShape = Object.keys(input).every((k) => k === 'shape');
  return mutateLayout(
    (l) => {
      const r = findOr404(l.rooms, id, 'Raum');
      const floor = findOr404(l.floors, input.floorId ?? r.floorId, 'Etage');
      Object.assign(r, roomValues(input, floor, r), { floorId: floor.id });
      return clone(r);
    },
    onlyShape ? null : 'room.update',
    (r) => r.name + (cancelled ? ` (${cancelled} Buchungen storniert)` : ''),
  );
}

async function deleteRoom(id) {
  requireAdmin();
  const room = findOr404(cache.layout.rooms, id, 'Raum');
  const cancelled = await cancelFutureInRooms([id], `Raum „${room.name}“ wurde entfernt`);
  await mutateLayout(
    (l) => {
      l.rooms = l.rooms.filter((r) => r.id !== id);
    },
    'room.delete',
    `${room.name} (${cancelled} Buchungen storniert)`,
  );
  return { cancelledBookings: cancelled };
}

async function loadDemoLayout() {
  return mutateLayout(
    (l) => {
      if (l.buildings.length) throw fail(409, 'Es sind bereits Gebäude angelegt. Das Beispiel kann nur in einen leeren Raumplaner geladen werden.');
      const building = { id: l.nextId++, name: DEMO.building.name, address: DEMO.building.address, sort: 0 };
      l.buildings.push(building);
      for (const floor of DEMO.floors) {
        const f = { id: l.nextId++, buildingId: building.id, name: floor.name, level: floor.level, width: 1200, height: 800, imageAssetId: null };
        l.floors.push(f);
        for (const room of floor.rooms) {
          l.rooms.push({
            id: l.nextId++,
            floorId: f.id,
            name: room.name,
            kind: room.kind,
            capacity: room.capacity ?? 0,
            equipment: room.equipment ?? [],
            description: room.description ?? '',
            shape: room.shape,
            bookable: true,
          });
        }
      }
      return { bookings: 0 };
    },
    'demo.load',
    'Beispielgebäude geladen',
  );
}

// ---------------------------------------------------------------------- Buchungen: Lesen

async function listBookings(q) {
  const from = toTimestamp(q.get('from'), 'Von');
  const to = toTimestamp(q.get('to'), 'Bis');
  if (!(to > from)) throw fail(400, 'Ungültiger Zeitraum.');
  let rows;
  if (from >= startedAt - WINDOW_PAST_MS) rows = confirmedInCache().filter((b) => overlaps(b, from, to));
  else {
    const snap = await db.collection('bookings').where('end', '>', from).where('start', '<', to).get();
    rows = snap.docs.map((d) => ({ id: d.id, ...d.data() })).filter((b) => b.status === 'confirmed');
  }
  const roomId = Number(q.get('roomId')) || null;
  const floorId = Number(q.get('floorId')) || null;
  const buildingId = Number(q.get('buildingId')) || null;
  rows = rows.filter((b) => {
    const room = roomOf(b.roomId);
    if (roomId && b.roomId !== roomId) return false;
    if (floorId && room?.floorId !== floorId) return false;
    if (buildingId && floorOf(room?.floorId)?.buildingId !== buildingId) return false;
    return true;
  });
  rows.sort((a, b) => a.start - b.start);
  return apiBookings(rows);
}

async function mine(scope) {
  if (!me.id) return [];
  const now = Date.now();
  const involved = (b) => b.userId === me.id || (b.attendeeIds || []).includes(me.id);
  let rows;
  if (scope === 'past') {
    const [own, invited] = await Promise.all([
      db.collection('bookings').where('userId', '==', me.id).where('end', '<=', now).get(),
      db.collection('bookings').where('attendeeIds', 'array-contains', me.id).get(),
    ]);
    const map = new Map();
    for (const d of [...own.docs, ...invited.docs]) map.set(d.id, { id: d.id, ...d.data() });
    rows = [...map.values()].filter((b) => b.status === 'confirmed' && b.type === 'booking' && b.end <= now).sort((a, b) => b.start - a.start).slice(0, 100);
  } else {
    rows = confirmedInCache()
      .filter((b) => b.type === 'booking' && b.end > now && involved(b))
      .sort((a, b) => a.start - b.start)
      .slice(0, 200);
  }
  return apiBookings(rows);
}

async function availability(q) {
  const start = toTimestamp(q.get('start'), 'Beginn');
  const end = toTimestamp(q.get('end'), 'Ende');
  if (!(end > start)) throw fail(400, 'Das Ende muss nach dem Beginn liegen.');
  const exclude = q.get('exclude') || '';
  let rows;
  if (start >= startedAt - WINDOW_PAST_MS) rows = confirmedInCache().filter((b) => b.id !== exclude && overlaps(b, start, end));
  else {
    const snap = await db.collection('bookings').where('end', '>', start).where('start', '<', end).get();
    rows = snap.docs.map((d) => ({ id: d.id, ...d.data() })).filter((b) => b.status === 'confirmed' && b.id !== exclude);
  }
  const list = await apiBookings(rows.sort((a, b) => a.start - b.start));
  const busy = {};
  for (const b of list) (busy[b.room.id] ||= []).push(b);
  return { start, end, busy };
}

// ---------------------------------------------------------------------- Buchungen: Schreiben

async function createBooking(input) {
  requireWrite();
  const admin = isAdmin();
  const type = input.type === 'block' ? 'block' : 'booking';
  if (type === 'block' && !admin) throw fail(403, 'Nur die Administration kann Räume sperren.');
  const room = bookableRoom(Number(input.roomId));
  if (!room.bookable && !admin) throw fail(400, 'Dieser Raum ist derzeit nicht buchbar.');
  const title = type === 'block' ? optString(input.title, 'Grund', { max: 200 }) || 'Gesperrt' : reqString(input.title, 'Titel', { max: 200 });
  const description = optString(input.description, 'Beschreibung', { max: 1000 });
  const start = toTimestamp(input.start, 'Beginn');
  const end = toTimestamp(input.end, 'Ende');
  checkTimes(start, end);
  const attendeeIds = type === 'booking' ? normalizeAttendeeIds(input.attendees, me.id) : [];

  let occurrences = [{ start, end }];
  const rule = input.recurrence && input.recurrence.freq && input.recurrence.freq !== 'none' ? input.recurrence : null;
  if (rule) {
    if (!parseDateKey(rule.until)) throw fail(400, 'Bitte ein gültiges Enddatum für die Serie angeben.');
    try {
      occurrences = expandRecurrence(start, end, rule, tz());
    } catch (err) {
      throw fail(400, err.message);
    }
    const maxDays = cache.settings.max_days_ahead;
    if (!admin && occurrences[occurrences.length - 1].start > Date.now() + maxDays * 86400000) {
      throw fail(400, `Serientermine dürfen höchstens ${maxDays} Tage in die Zukunft reichen.`);
    }
  }
  const skipConflicts = toBool(input.skipConflicts);

  return withLock(
    `room-${room.id}`,
    async () => {
      const first = occurrences[0];
      const last = occurrences[occurrences.length - 1];
      const existing = await freshRoomBookings(room.id, first.start, last.end);
      const conflicting = [];
      const toCancel = new Map();
      for (const occ of occurrences) {
        const found = existing.filter((b) => overlaps(b, occ.start, occ.end));
        if (!found.length) continue;
        if (type === 'block' && found.every((b) => b.type === 'booking')) for (const b of found) toCancel.set(b.id, b);
        else conflicting.push({ ...occ, conflicts: found });
      }
      let planned = occurrences;
      if (conflicting.length) {
        const canSkip = skipConflicts && occurrences.length > 1 && conflicting.length < occurrences.length;
        if (!canSkip) {
          throw fail(
            409,
            occurrences.length > 1 ? `${conflicting.length} von ${occurrences.length} Terminen sind bereits belegt.` : 'Der Raum ist in diesem Zeitraum bereits belegt.',
            { conflicts: await conflictPayload(conflicting), occurrences: occurrences.length },
          );
        }
        const blocked = new Set(conflicting.map((o) => o.start));
        planned = occurrences.filter((o) => !blocked.has(o.start));
      }
      // Der Raum wird gleich gesperrt: keine „Raum frei“-Meldungen für diese Stornos
      if (toCancel.size) await cancelRows([...toCancel.values()], `Raum gesperrt – ${title}`, { checkFreed: false });

      const now = Date.now();
      const seriesId = planned.length > 1 ? db.collection('bookings').doc().id : null;
      const docs = planned.map((occ) => ({
        id: db.collection('bookings').doc().id,
        roomId: room.id,
        userId: me.id,
        type,
        title,
        description,
        start: occ.start,
        end: occ.end,
        attendeeIds,
        seriesId,
        status: 'confirmed',
        cancelReason: null,
        cancelledBy: null,
        seq: 0,
        createdAt: now,
        updatedAt: now,
        timeChangedAt: now,
      }));
      await inBatches(docs, 6, ({ id, ...data }) => db.doc(`bookings/${id}`).set(data));
      const lost = await verifyNoOverlap(room.id, docs);
      const lostIds = new Set(lost.map((b) => b.id));
      const kept = docs.filter((b) => !lostIds.has(b.id));
      if (!kept.length) throw fail(409, 'Der Raum wurde gerade von jemand anderem gebucht. Bitte wähle eine andere Zeit.');
      for (const b of kept) cache.bookings.set(b.id, b);
      await notifyCreated(kept);
      audit(
        type === 'block' ? 'block.create' : 'booking.create',
        `${room.name}: „${title}“ – ${kept.length > 1 ? `${kept.length} Termine ab ` : ''}${formatRange(kept[0].start, kept[0].end, tz())}`,
      );
      return { bookings: await apiBookings(kept), skipped: occurrences.length - kept.length, cancelled: toCancel.size };
    },
    'Gerade bucht jemand anderes diesen Raum. Bitte versuche es in ein paar Sekunden noch einmal.',
  );
}

function assertCanModify(b) {
  requireWrite();
  if (!isAdmin() && b.userId !== me.id) throw fail(403, 'Nur die buchende Person oder die Administration kann diese Buchung ändern.');
}

async function updateBooking(id, input) {
  const before = await freshBooking(id);
  assertCanModify(before);
  if (before.status !== 'confirmed') throw fail(400, 'Diese Buchung wurde bereits storniert.');
  const now = Date.now();
  if (before.end <= now) throw fail(400, 'Vergangene Buchungen können nicht mehr geändert werden.');
  const roomId = input.roomId !== undefined ? Number(input.roomId) : before.roomId;
  const start = input.start !== undefined ? toTimestamp(input.start, 'Beginn') : before.start;
  const end = input.end !== undefined ? toTimestamp(input.end, 'Ende') : before.end;
  let title = before.title;
  if (input.title !== undefined) {
    title = before.type === 'block' ? optString(input.title, 'Grund', { max: 200 }) || 'Gesperrt' : reqString(input.title, 'Titel', { max: 200 });
  }
  const description = input.description !== undefined ? optString(input.description, 'Beschreibung', { max: 1000 }) : before.description || '';
  const timeChanged = roomId !== before.roomId || start !== before.start || end !== before.end;
  if (timeChanged) {
    const room = bookableRoom(roomId);
    if (!room.bookable && !isAdmin()) throw fail(400, 'Dieser Raum ist derzeit nicht buchbar.');
    checkTimes(start, end, { allowStartedAt: before.start });
  }
  const attendeeIds = input.attendees !== undefined && before.type === 'booking' ? normalizeAttendeeIds(input.attendees, before.userId) : before.attendeeIds || [];
  const patch = {
    roomId,
    start,
    end,
    title,
    description,
    attendeeIds,
    seq: (before.seq || 0) + 1,
    updatedAt: now,
    ...(timeChanged ? { timeChangedAt: now } : {}),
  };

  const write = async () => {
    if (timeChanged) {
      const found = (await freshRoomBookings(roomId, start, end)).filter((b) => b.id !== before.id && overlaps(b, start, end));
      if (found.length) {
        throw fail(409, 'Der Raum ist in diesem Zeitraum bereits belegt.', { conflicts: await conflictPayload([{ start, end, conflicts: found }]), occurrences: 1 });
      }
    }
    await db.doc(`bookings/${before.id}`).update(patch);
    const after = { ...before, ...patch };
    cache.bookings.set(after.id, after);
    return after;
  };
  const after = timeChanged ? await withLock(`room-${roomId}`, write, 'Gerade bucht jemand anderes diesen Raum. Bitte versuche es in ein paar Sekunden noch einmal.') : await write();

  const prev = new Set(before.attendeeIds || []);
  const next = new Set(attendeeIds);
  await notifyUpdated(after, before, attendeeIds.filter((x) => !prev.has(x)), [...prev].filter((x) => !next.has(x)));
  audit('booking.update', `${roomOf(after.roomId)?.name || 'Raum'}: „${after.title}“ – ${formatRange(after.start, after.end, tz())}`);
  if (timeChanged) checkWatches(before.roomId, before.start, before.end);
  return (await apiBookings([after]))[0];
}

/** Storniert (frisch gelesene) Buchungen inkl. Benachrichtigungen und Raum-frei-Prüfung. */
async function cancelRows(rows, reason, { checkFreed = true } = {}) {
  if (!rows.length) return;
  const now = Date.now();
  await inBatches(rows, 6, (r) =>
    db.doc(`bookings/${r.id}`).update({ status: 'cancelled', seq: (r.seq || 0) + 1, cancelReason: reason || null, cancelledBy: me.id, updatedAt: now }),
  );
  for (const r of rows) {
    r.status = 'cancelled';
    cache.bookings.set(r.id, { ...r, cancelReason: reason || null, cancelledBy: me.id, updatedAt: now });
  }
  await notifyCancelled(rows, reason);
  audit('booking.cancel', `${roomOf(rows[0].roomId)?.name || 'Raum'}: „${rows[0].title}“ – ${rows.length > 1 ? `${rows.length} Termine` : formatRange(rows[0].start, rows[0].end, tz())}${reason ? ` (${reason})` : ''}`);
  const byRoom = new Map();
  for (const r of rows) {
    const cur = byRoom.get(r.roomId) || { from: Infinity, to: -Infinity };
    byRoom.set(r.roomId, { from: Math.min(cur.from, r.start), to: Math.max(cur.to, r.end) });
  }
  if (checkFreed) for (const [roomId, range] of byRoom) checkWatches(roomId, range.from, range.to);
}

async function cancelBooking(id, { scope = 'single', reason } = {}) {
  const b = await freshBooking(id);
  assertCanModify(b);
  if (b.status === 'cancelled') return { cancelled: 0 };
  if (b.end <= Date.now()) throw fail(400, 'Vergangene Buchungen können nicht storniert werden.');
  const why = optString(reason, 'Grund', { max: 300 });
  let rows = [b];
  if (scope === 'series' && b.seriesId) {
    const snap = await db.collection('bookings').where('seriesId', '==', b.seriesId).get();
    rows = snap.docs.map((d) => ({ id: d.id, ...d.data() })).filter((x) => x.status === 'confirmed' && x.start >= b.start);
  }
  await cancelRows(rows, why);
  return { cancelled: rows.length };
}

async function endBooking(id) {
  const b = await freshBooking(id);
  assertCanModify(b);
  if (b.status !== 'confirmed') throw fail(400, 'Diese Buchung wurde bereits storniert.');
  const now = Date.now();
  if (b.start > now) throw fail(400, 'Der Termin hat noch nicht begonnen – du kannst ihn stattdessen stornieren.');
  if (b.end <= now) throw fail(400, 'Der Termin ist bereits beendet.');
  const newEnd = Math.max(Math.ceil(now / 60000) * 60000, b.start + 60000);
  if (newEnd < b.end) {
    await db.doc(`bookings/${b.id}`).update({ end: newEnd, seq: (b.seq || 0) + 1, updatedAt: now });
    cache.bookings.set(b.id, { ...b, end: newEnd, updatedAt: now });
    audit('booking.end', `${roomOf(b.roomId)?.name || 'Raum'}: „${b.title}“ vorzeitig beendet`);
    checkWatches(b.roomId, newEnd, b.end);
  }
  return (await apiBookings([{ ...b, end: Math.min(newEnd, b.end) }]))[0];
}

// ---------------------------------------------------------------------- Raum-Wünsche

async function listWatches() {
  if (!me.id) return [];
  const snap = await db.collection('watches').where('userId', '==', me.id).get();
  const now = Date.now();
  return snap.docs
    .map((d) => ({ id: d.id, ...d.data() }))
    .filter((w) => w.end > now)
    .sort((a, b) => a.start - b.start)
    .map((w) => {
      const room = roomOf(w.roomId);
      const floor = room && floorOf(room.floorId);
      return {
        id: w.id,
        roomId: w.roomId,
        roomName: room?.name || 'Gelöschter Raum',
        floorName: floor?.name || '–',
        buildingName: buildingOf(floor?.buildingId)?.name || '–',
        start: w.start,
        end: w.end,
        createdAt: w.createdAt,
      };
    });
}

async function createWatch(input) {
  requireWrite();
  const room = bookableRoom(Number(input.roomId));
  const start = toTimestamp(input.start, 'Beginn');
  const end = toTimestamp(input.end, 'Ende');
  const now = Date.now();
  if (!(end > start)) throw fail(400, 'Das Ende muss nach dem Beginn liegen.');
  if (end <= now) throw fail(400, 'Der Zeitraum liegt in der Vergangenheit.');
  const fresh = await freshRoomBookings(room.id, Math.max(start, now), end);
  if (!fresh.some((b) => overlaps(b, Math.max(start, now), end))) return { free: true };
  const existing = await listWatches();
  const dup = existing.find((w) => w.roomId === room.id && w.start === start && w.end === end);
  if (dup) return { free: false, watch: dup };
  if (existing.length >= MAX_WATCHES) throw fail(400, `Du hast bereits ${MAX_WATCHES} aktive Raum-Wünsche. Bitte entferne zuerst ältere.`);
  const ref = await db.collection('watches').add({ userId: me.id, roomId: room.id, start, end, createdAt: now });
  audit('watch.create', `${room.name}: ${formatRange(start, end, tz())}`);
  return { free: false, watch: (await listWatches()).find((w) => w.id === ref.id) };
}

async function deleteWatch(id) {
  requireWrite();
  const snap = await db.doc(`watches/${id}`).get();
  if (!snap.exists || snap.data().userId !== me.id) throw fail(404, 'Raum-Wunsch nicht gefunden.');
  await db.doc(`watches/${id}`).delete();
  return { ok: true };
}

// ---------------------------------------------------------------------- Benachrichtigungen gelesen

async function markRead(body) {
  if (!me.id) return { unreadCount: 0 };
  const targets = body.all ? cache.notifications.filter((n) => !n.read) : cache.notifications.filter((n) => !n.read && (body.ids || []).includes(n.id));
  for (const n of targets) n.read = true;
  live?.onUnread?.(unreadCount());
  await inBatches(targets, 6, (n) => db.doc(`notifications/${n.id}`).update({ read: true }).catch(() => {}));
  return { unreadCount: unreadCount() };
}

// ---------------------------------------------------------------------- Verwaltung

async function updateSettings(input) {
  return withLock('settings', async () => {
    const snap = await db.doc('settings/main').get();
    const current = { ...DEFAULT_SETTINGS, timezone: 'Europe/Berlin', admin_ids: [], ...(snap.exists ? snap.data() : {}) };
    const next = { ...normalizeSettings(input, current), timezone: current.timezone, admin_ids: current.admin_ids || [] };
    if (input.timezone !== undefined) {
      const zone = String(input.timezone).trim();
      if (!isValidTimezone(zone)) throw fail(400, `Unbekannte Zeitzone: ${zone}`);
      next.timezone = zone;
    }
    await db.doc('settings/main').set(next);
    cache.settings = next;
    state.config = config();
    audit('settings.update', Object.keys(input).join(', '));
    return { ...next };
  });
}

async function auditList(limit) {
  const snap = await db.collection('audit').orderBy('at', 'desc').limit(Math.min(limit, 500)).get();
  const rows = snap.docs.map((d) => ({ id: d.id, ...d.data() }));
  const ps = await profilesFor(rows.map((r) => r.actorId));
  return rows.map((r) => ({ id: r.id, action: r.action, details: r.details, createdAt: r.at, userName: nameFrom(ps, r.actorId) }));
}

async function peopleList() {
  const ids = [...new Set([...cache.people.keys(), ...(me.id ? [me.id] : [])])];
  const ps = await profilesFor(ids);
  const admins = new Set(cache.settings.admin_ids || []);
  return ids
    .map((id) => ({
      id,
      name: nameFrom(ps, id),
      email: emailFrom(ps, id),
      isMe: id === me.id,
      isAdmin: admins.has(id) || (id === me.id && me.isOwner),
      lastSeen: cache.people.get(id)?.lastSeen || null,
    }))
    .sort((a, b) => Number(b.isMe) - Number(a.isMe) || a.name.localeCompare(b.name, 'de'));
}

async function setAdmin(id, { admin }) {
  if (!me.isOwner) throw fail(403, 'Rollen vergeben kann nur die Person, der der Raumplaner gehört.');
  return withLock('settings', async () => {
    const snap = await db.doc('settings/main').get();
    const current = { ...DEFAULT_SETTINGS, timezone: 'Europe/Berlin', admin_ids: [], ...(snap.exists ? snap.data() : {}) };
    const ids = new Set(current.admin_ids || []);
    if (toBool(admin)) ids.add(id);
    else ids.delete(id);
    const next = { ...current, admin_ids: [...ids] };
    await db.doc('settings/main').set(next);
    cache.settings = next;
    audit('user.role', `${toBool(admin) ? 'Administration' : 'Mitarbeiter/in'}`);
    return { ok: true };
  });
}

async function systemInfo() {
  const now = Date.now();
  let storage = null;
  if (assets) {
    try {
      const res = await assets.list();
      storage = res.usage;
    } catch {
      storage = null;
    }
  }
  return {
    hosted: true,
    counts: {
      rooms: cache.layout.rooms.filter((r) => r.kind !== 'area').length,
      upcomingBookings: confirmedInCache().filter((b) => b.end > now).length,
      people: cache.people.size,
    },
    storage,
  };
}

async function exportAll() {
  if (!downloads) throw fail(400, 'Downloads sind in dieser Ansicht nicht verfügbar.');
  const [bookings, watches] = await Promise.all([db.collection('bookings').get(), db.collection('watches').get()]);
  const data = {
    exportedAt: new Date().toISOString(),
    format: 'raumplaner-web-export/1',
    settings: cache.settings,
    layout: cache.layout,
    bookings: bookings.docs.map((d) => ({ id: d.id, ...d.data() })),
    watches: watches.docs.map((d) => ({ id: d.id, ...d.data() })),
  };
  const day = new Date().toISOString().slice(0, 10);
  await downloads.save({ filename: `raumplaner-export-${day}.json`, data: JSON.stringify(data, null, 2) });
  return { saved: true };
}
