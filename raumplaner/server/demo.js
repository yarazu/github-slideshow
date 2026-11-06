import { addDaysToKey, dateKey, fromLocal, weekdayOfKey } from '../public/shared/time.js';
import { conflict } from './errors.js';

const rect = (x, y, w, h) => ({ type: 'rect', x, y, w, h });

/** Beispielgebäude, damit man sofort sieht, wie Lagepläne funktionieren. */
const DEMO = {
  building: { name: 'Hauptgebäude', address: 'Musterstraße 1, 12345 Musterstadt' },
  floors: [
    {
      name: 'Erdgeschoss',
      level: 0,
      rooms: [
        { name: 'Rhein', kind: 'room', capacity: 12, equipment: ['Beamer', 'Videokonferenz', 'Whiteboard', 'Barrierefrei'], shape: rect(40, 40, 380, 300), description: 'Großer Besprechungsraum mit Blick auf den Innenhof.' },
        { name: 'Main', kind: 'room', capacity: 6, equipment: ['Bildschirm', 'Videokonferenz'], shape: rect(430, 40, 260, 300) },
        { name: 'Neckar', kind: 'room', capacity: 4, equipment: ['Bildschirm', 'Whiteboard'], shape: rect(700, 40, 200, 300) },
        { name: 'Küche', kind: 'area', shape: rect(910, 40, 250, 300) },
        { name: 'Flur', kind: 'area', shape: rect(40, 350, 1120, 100) },
        { name: 'Empfang', kind: 'area', shape: rect(40, 460, 260, 300) },
        { name: 'Mosel', kind: 'room', capacity: 8, equipment: ['Beamer', 'Flipchart', 'Barrierefrei'], shape: rect(310, 460, 330, 300) },
        { name: 'Treppe / Aufzug', kind: 'area', shape: rect(650, 460, 150, 300) },
        { name: 'WC', kind: 'area', shape: rect(810, 460, 120, 300) },
        { name: 'Ruhr', kind: 'room', capacity: 2, equipment: ['Telefon'], shape: rect(940, 460, 220, 145), description: 'Telefonbox für vertrauliche Gespräche.' },
        { name: 'Saar', kind: 'room', capacity: 3, equipment: ['Bildschirm'], shape: rect(940, 615, 220, 145) },
      ],
    },
    {
      name: '1. Obergeschoss',
      level: 1,
      rooms: [
        { name: 'Elbe', kind: 'room', capacity: 10, equipment: ['Bildschirm', 'Videokonferenz', 'Whiteboard'], shape: rect(40, 40, 330, 300) },
        { name: 'Spree', kind: 'room', capacity: 4, equipment: ['Bildschirm'], shape: rect(380, 40, 200, 300) },
        ...[0, 1, 2, 3, 4, 5, 6, 7].map((i) => ({
          name: `Arbeitsplatz ${i + 1}`,
          kind: 'desk',
          capacity: 1,
          equipment: ['Bildschirm'],
          shape: rect(600 + (i % 4) * 140, 55 + Math.floor(i / 4) * 150, 120, 120),
        })),
        { name: 'Flur', kind: 'area', shape: rect(40, 350, 1120, 100) },
        { name: 'Fokus 1', kind: 'room', capacity: 1, equipment: [], shape: rect(40, 460, 200, 300), description: 'Ruhiger Einzelraum zum konzentrierten Arbeiten.' },
        { name: 'Fokus 2', kind: 'room', capacity: 1, equipment: [], shape: rect(250, 460, 200, 300) },
        { name: 'Lounge', kind: 'area', shape: rect(460, 460, 180, 300) },
        { name: 'Treppe / Aufzug', kind: 'area', shape: rect(650, 460, 150, 300) },
        { name: 'WC', kind: 'area', shape: rect(810, 460, 120, 300) },
        { name: 'Donau', kind: 'room', capacity: 6, equipment: ['Beamer', 'Flipchart'], shape: rect(940, 460, 220, 300) },
      ],
    },
  ],
};

const SAMPLE_BOOKINGS = [
  { room: 'Rhein', title: 'Beispiel: Teammeeting', from: '09:00', to: '10:30' },
  { room: 'Main', title: 'Beispiel: Kundentermin', from: '11:00', to: '12:00' },
  { room: 'Neckar', title: 'Beispiel: Projekt-Abstimmung', from: '13:00', to: '14:00' },
  { room: 'Elbe', title: 'Beispiel: Workshop', from: '14:00', to: '16:30' },
  { room: 'Mosel', title: 'Beispiel: Schulung', from: '15:00', to: '17:00' },
  { room: 'Arbeitsplatz 2', title: 'Arbeitsplatz', from: '08:00', to: '17:00' },
];

export function loadDemo(ctx, actor, { withBookings = true } = {}) {
  const { db, clock, config } = ctx;
  if (db.get('SELECT COUNT(*) AS n FROM buildings').n > 0) {
    throw conflict('Es sind bereits Gebäude angelegt. Das Beispiel kann nur in eine leere Installation geladen werden.');
  }
  const now = clock.now();
  const tz = config.timezone;
  let bookings = 0;

  db.tx(() => {
    const b = db.run('INSERT INTO buildings (name, address, sort, created_at) VALUES (?, ?, 0, ?)', [DEMO.building.name, DEMO.building.address, now]);
    const roomIds = new Map();
    for (const floor of DEMO.floors) {
      const f = db.run('INSERT INTO floors (building_id, name, level, width, height, created_at) VALUES (?, ?, ?, 1200, 800, ?)', [
        b.lastInsertRowid,
        floor.name,
        floor.level,
        now,
      ]);
      for (const room of floor.rooms) {
        const r = db.run(
          `INSERT INTO rooms (floor_id, name, kind, capacity, equipment, description, shape, bookable, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)`,
          [
            f.lastInsertRowid,
            room.name,
            room.kind,
            room.capacity ?? 0,
            JSON.stringify(room.equipment ?? []),
            room.description ?? '',
            JSON.stringify(room.shape),
            now,
            now,
          ],
        );
        if (room.kind !== 'area' && !roomIds.has(room.name)) roomIds.set(room.name, r.lastInsertRowid);
      }
    }

    if (withBookings) {
      // Heute (soweit noch in der Zukunft) und am nächsten Werktag
      const today = dateKey(now, tz);
      let next = addDaysToKey(today, 1);
      while ([0, 6].includes(weekdayOfKey(next))) next = addDaysToKey(next, 1);
      for (const day of [today, next]) {
        for (const s of SAMPLE_BOOKINGS) {
          const start = fromLocal(day, s.from, tz);
          const end = fromLocal(day, s.to, tz);
          if (start <= now) continue;
          db.run(
            `INSERT INTO bookings (room_id, user_id, type, title, description, start_ts, end_ts, time_changed_at, created_at, updated_at)
             VALUES (?, ?, 'booking', ?, 'Automatisch angelegte Beispielbuchung – kann gelöscht werden.', ?, ?, ?, ?, ?)`,
            [roomIds.get(s.room), actor.id, s.title, start, end, now, now, now],
          );
          bookings += 1;
        }
      }
    }
    ctx.audit(actor.id, 'demo.load', `Beispielgebäude geladen (${bookings} Beispielbuchungen)`);
    db.afterCommit(() => {
      ctx.hub.broadcast('layout-changed', {});
      ctx.hub.broadcast('bookings-changed', {});
    });
  });
  return { bookings };
}
