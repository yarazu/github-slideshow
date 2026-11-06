import * as T from '../shared/time.js';
import { get } from './api.js';

/** Globaler Zustand der App. */
export const state = {
  config: null,
  me: null,
  calendarUrl: '',
  layout: { buildings: [], floors: [], rooms: [] },
  unread: 0,
  online: true,
  directory: null,
};

export const tz = () => state.config?.timezone || 'Europe/Berlin';

export const fmt = {
  time: (ms) => T.formatTime(ms, tz()),
  date: (ms) => T.formatDate(ms, tz()),
  dateLong: (ms) => T.formatDateLong(ms, tz()),
  dateTime: (ms) => T.formatDateTime(ms, tz()),
  range: (s, e) => T.formatRange(s, e, tz()),
  duration: T.formatDuration,
};

export const dateKey = (ms) => T.dateKey(ms, tz());
export const timeKey = (ms) => T.timeKey(ms, tz());
export const fromLocal = (d, t) => T.fromLocal(d, t, tz());
export const dayBounds = (key) => T.dayBounds(key, tz());
export const todayKey = () => dateKey(Date.now());
export const addDays = T.addDaysToKey;
export const minutesOfDay = (ms) => T.minutesOfDay(ms, tz());

export const slotMinutes = () => state.config?.slotMinutes || 15;
export const nextSlot = (ms = Date.now()) => T.ceilToSlot(ms, slotMinutes());
export const currentSlot = (ms = Date.now()) => T.floorToSlot(ms, slotMinutes());

export const isAdmin = () => state.me?.role === 'admin';

export async function loadLayout() {
  state.layout = await get('/api/layout');
  return state.layout;
}

export async function loadDirectory(force = false) {
  if (!state.directory || force) state.directory = await get('/api/users/directory');
  return state.directory;
}

export const roomById = (id) => state.layout.rooms.find((r) => r.id === Number(id));
export const floorById = (id) => state.layout.floors.find((f) => f.id === Number(id));
export const buildingById = (id) => state.layout.buildings.find((b) => b.id === Number(id));

export function sortedFloors() {
  const order = new Map(state.layout.buildings.map((b, i) => [b.id, i]));
  return [...state.layout.floors].sort((a, b) => (order.get(a.buildingId) ?? 0) - (order.get(b.buildingId) ?? 0) || a.level - b.level);
}

export const roomsOfFloor = (floorId) => state.layout.rooms.filter((r) => r.floorId === floorId);

/** Buchbare Räume/Arbeitsplätze in Lageplan-Reihenfolge. */
export function bookableRooms({ includeDisabled = false } = {}) {
  const floors = sortedFloors();
  const pos = new Map(floors.map((f, i) => [f.id, i]));
  return state.layout.rooms
    .filter((r) => r.kind !== 'area' && (includeDisabled || r.bookable))
    .sort((a, b) => (pos.get(a.floorId) ?? 0) - (pos.get(b.floorId) ?? 0) || a.name.localeCompare(b.name, 'de', { numeric: true }));
}

export function roomPlace(room) {
  const floor = floorById(room.floorId);
  const building = floor && buildingById(floor.buildingId);
  return [floor?.name, building?.name].filter(Boolean).join(' · ');
}

export const KIND_LABEL = { room: 'Raum', desk: 'Arbeitsplatz', area: 'Bereich' };
