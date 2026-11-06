import express from 'express';
import { csrfGuard, loadUser, requireAdmin } from './auth.js';
import { HttpError, isBookingConflictError } from './errors.js';
import { adminRoutes } from './routes/admin.js';
import { authRoutes } from './routes/auth.js';
import { bookingRoutes } from './routes/bookings.js';
import { calendarFeed } from './routes/calendar.js';
import { layoutRoutes } from './routes/layout.js';
import { notificationRoutes } from './routes/notifications.js';

const CSP = [
  "default-src 'self'",
  "img-src 'self' data: blob:",
  "style-src 'self' 'unsafe-inline'",
  "script-src 'self'",
  "connect-src 'self'",
  "font-src 'self'",
  "object-src 'none'",
  "frame-ancestors 'none'",
  "base-uri 'self'",
  "form-action 'self'",
].join('; ');

function securityHeaders(req, res, next) {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Referrer-Policy', 'same-origin');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
  if (!req.path.startsWith('/api/floors/')) res.setHeader('Content-Security-Policy', CSP);
  next();
}

export function createApp(ctx) {
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', ctx.config.trustProxy);
  app.use(securityHeaders);

  app.get('/api/health', (req, res) => {
    ctx.db.get('SELECT 1 AS ok');
    res.json({ status: 'ok', version: ctx.config.version, uptimeSeconds: Math.round((Date.now() - ctx.startedAt) / 1000) });
  });

  app.use(express.json({ limit: '1mb' }));
  app.use('/api', loadUser(ctx));
  app.use('/api', (req, res, next) => {
    res.setHeader('Cache-Control', 'no-store');
    next();
  });
  app.use('/api', csrfGuard);
  app.use('/api', authRoutes(ctx));
  app.use('/api', layoutRoutes(ctx));
  app.use('/api', bookingRoutes(ctx));
  app.use('/api', notificationRoutes(ctx));
  app.use('/api/admin', requireAdmin, adminRoutes(ctx));
  app.use('/api', (req, res) => res.status(404).json({ error: 'not_found', message: 'Unbekannter API-Pfad.' }));

  app.get('/cal/:file', calendarFeed(ctx));

  app.use(
    express.static(ctx.config.publicDir, {
      index: 'index.html',
      etag: true,
      lastModified: true,
      setHeaders: (res) => res.setHeader('Cache-Control', 'no-cache'),
    }),
  );

  // Fehlerbehandlung: verständliche Meldungen statt Stacktraces
  // eslint-disable-next-line no-unused-vars
  app.use((err, req, res, next) => {
    if (err instanceof HttpError) {
      res.status(err.status).json({ error: err.code, message: err.message, ...(err.extra || {}) });
      return;
    }
    if (err?.type === 'entity.too.large') {
      res.status(413).json({ error: 'too_large', message: 'Die Datei bzw. Anfrage ist zu groß (Grundrisse max. 15 MB).' });
      return;
    }
    if (err?.type === 'entity.parse.failed') {
      res.status(400).json({ error: 'bad_json', message: 'Ungültige Anfrage.' });
      return;
    }
    if (isBookingConflictError(err)) {
      res.status(409).json({ error: 'conflict', message: 'Der Raum ist in diesem Zeitraum bereits belegt.' });
      return;
    }
    ctx.log.error('[http] Unerwarteter Fehler bei', req.method, req.originalUrl, err);
    if (res.headersSent) return;
    res.status(500).json({ error: 'internal', message: 'Interner Fehler. Bitte versuche es erneut.' });
  });

  return app;
}
