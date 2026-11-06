import express from 'express';
import { requireAdmin, requireUser } from '../auth.js';
import { notFound } from '../errors.js';
import { IMAGE_TYPES } from '../layout.js';

export function layoutRoutes(ctx) {
  const r = express.Router();
  const { layout } = ctx;

  r.get('/layout', requireUser, (req, res) => res.json(layout.full()));

  r.get('/floors/:id/image', requireUser, (req, res) => {
    const img = layout.floorImage(req.params.id);
    if (!img) throw notFound('Kein Grundriss vorhanden.');
    res.setHeader('Content-Type', img.mime);
    res.setHeader('Cache-Control', 'private, max-age=31536000, immutable');
    if (img.mime === 'image/svg+xml') {
      // SVG darf keine Skripte ausführen, selbst wenn man die Datei direkt öffnet.
      res.setHeader('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; img-src data:; sandbox");
    }
    res.send(Buffer.from(img.data));
  });

  // ---- Verwaltung (nur Admins)
  r.post('/buildings', requireAdmin, (req, res) => res.status(201).json(layout.createBuilding(req.user, req.body || {})));
  r.put('/buildings/:id', requireAdmin, (req, res) => res.json(layout.updateBuilding(req.user, req.params.id, req.body || {})));
  r.delete('/buildings/:id', requireAdmin, (req, res) => res.json(layout.deleteBuilding(req.user, req.params.id)));

  r.post('/floors', requireAdmin, (req, res) => res.status(201).json(layout.createFloor(req.user, req.body || {})));
  r.put('/floors/:id', requireAdmin, (req, res) => res.json(layout.updateFloor(req.user, req.params.id, req.body || {})));
  r.delete('/floors/:id', requireAdmin, (req, res) => res.json(layout.deleteFloor(req.user, req.params.id)));

  r.put(
    '/floors/:id/image',
    requireAdmin,
    express.raw({ type: IMAGE_TYPES, limit: '15mb' }),
    (req, res) => {
      const body = Buffer.isBuffer(req.body) ? req.body : null;
      res.json(layout.setFloorImage(req.user, req.params.id, body, { width: req.query.width, height: req.query.height }));
    },
  );
  r.delete('/floors/:id/image', requireAdmin, (req, res) => res.json(layout.removeFloorImage(req.user, req.params.id)));

  r.post('/rooms', requireAdmin, (req, res) => res.status(201).json(layout.createRoom(req.user, req.body || {})));
  r.put('/rooms/:id', requireAdmin, (req, res) => res.json(layout.updateRoom(req.user, req.params.id, req.body || {})));
  r.delete('/rooms/:id', requireAdmin, (req, res) => res.json(layout.deleteRoom(req.user, req.params.id)));

  return r;
}
