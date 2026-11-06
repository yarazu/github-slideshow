import express from 'express';
import { requireUser } from '../auth.js';
import { forbidden, notFound } from '../errors.js';
import { icsCalendar } from '../ics.js';
import { toId, toTimestamp } from '../validate.js';

export function bookingRoutes(ctx) {
  const r = express.Router();
  const { bookings, watches, notifier } = ctx;

  r.use(['/bookings', '/availability', '/watches'], requireUser);

  r.get('/bookings', (req, res) => {
    const q = req.query;
    res.json(
      bookings.list(
        {
          from: toTimestamp(q.from, 'Von'),
          to: toTimestamp(q.to, 'Bis'),
          roomId: q.roomId ? toId(q.roomId, 'Raum') : null,
          floorId: q.floorId ? toId(q.floorId, 'Etage') : null,
          buildingId: q.buildingId ? toId(q.buildingId, 'Gebäude') : null,
        },
        req.user,
      ),
    );
  });

  r.get('/bookings/mine', (req, res) => {
    res.json(bookings.mine(req.user, { scope: req.query.scope === 'past' ? 'past' : 'upcoming' }));
  });

  r.get('/bookings/:id', (req, res) => res.json(bookings.get(toId(req.params.id), req.user)));

  r.get('/bookings/:id/ics', (req, res) => {
    const row = bookings.loadFull(toId(req.params.id));
    if (!row) throw notFound('Buchung nicht gefunden.');
    if (!bookings.canSeeDetails(row, req.user)) throw forbidden();
    const ics = icsCalendar({ method: 'PUBLISH', events: [notifier.icsLines(row, row.status === 'cancelled' ? 'CANCELLED' : 'CONFIRMED')] });
    res.setHeader('Content-Type', 'text/calendar; charset=utf-8');
    res.setHeader('Content-Disposition', `attachment; filename="termin-${row.id}.ics"`);
    res.send(ics);
  });

  r.post('/bookings', (req, res) => res.status(201).json(bookings.create(req.user, req.body || {})));
  r.put('/bookings/:id', (req, res) => res.json(bookings.update(req.user, req.params.id, req.body || {})));
  r.post('/bookings/:id/cancel', (req, res) => res.json(bookings.cancel(req.user, req.params.id, req.body || {})));
  r.post('/bookings/:id/end', (req, res) => res.json(bookings.endNow(req.user, req.params.id)));

  r.get('/availability', (req, res) => {
    res.json(
      bookings.availability(
        {
          start: toTimestamp(req.query.start, 'Beginn'),
          end: toTimestamp(req.query.end, 'Ende'),
          excludeId: req.query.exclude ? toId(req.query.exclude) : 0,
        },
        req.user,
      ),
    );
  });

  r.get('/watches', (req, res) => res.json(watches.list(req.user)));
  r.post('/watches', (req, res) => res.status(201).json(watches.create(req.user, req.body || {})));
  r.delete('/watches/:id', (req, res) => {
    if (!watches.remove(req.user, req.params.id)) throw notFound('Raum-Wunsch nicht gefunden.');
    res.json({ ok: true });
  });

  return r;
}
