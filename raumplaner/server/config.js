import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { isValidTimezone } from '../public/shared/time.js';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
export const VERSION = pkg.version;

function toInt(value, fallback) {
  const n = Number.parseInt(value, 10);
  return Number.isFinite(n) ? n : fallback;
}

function toBool(value, fallback) {
  if (value === undefined || value === '') return fallback;
  return ['1', 'true', 'yes', 'ja', 'on'].includes(String(value).trim().toLowerCase());
}

/**
 * Liest die Konfiguration aus Umgebungsvariablen (optional aus einer .env-Datei).
 * Siehe .env.example für alle Optionen.
 */
export function loadConfig(overrides = {}) {
  const envFile = path.join(ROOT, '.env');
  if (!overrides.skipEnvFile && fs.existsSync(envFile)) {
    process.loadEnvFile(envFile);
  }
  const env = process.env;
  const port = toInt(env.PORT, 3000);
  const publicUrl = (env.PUBLIC_URL || `http://localhost:${port}`).replace(/\/+$/, '');
  const smtpPort = toInt(env.SMTP_PORT, 587);

  const config = {
    version: VERSION,
    root: ROOT,
    publicDir: path.join(ROOT, 'public'),
    port,
    host: env.HOST || '0.0.0.0',
    dataDir: path.resolve(ROOT, env.DATA_DIR || 'data'),
    timezone: env.APP_TIMEZONE || 'Europe/Berlin',
    publicUrl,
    trustProxy: toBool(env.TRUST_PROXY, false),
    cookieSecure: toBool(env.COOKIE_SECURE, publicUrl.startsWith('https://')),
    sessionDays: toInt(env.SESSION_DAYS, 30),
    smtp: {
      host: env.SMTP_HOST || '',
      port: smtpPort,
      secure: toBool(env.SMTP_SECURE, smtpPort === 465),
      user: env.SMTP_USER || '',
      pass: env.SMTP_PASS || '',
      from: env.SMTP_FROM || 'Raumplaner <raumplaner@localhost>',
      rejectUnauthorized: toBool(env.SMTP_TLS_REJECT_UNAUTHORIZED, true),
    },
    mailLogOnly: toBool(env.MAIL_LOG_ONLY, false),
    backupIntervalHours: toInt(env.BACKUP_INTERVAL_HOURS, 24),
    backupKeep: toInt(env.BACKUP_KEEP, 14),
    ...overrides,
  };

  if (!isValidTimezone(config.timezone)) {
    throw new Error(`Ungültige Zeitzone in APP_TIMEZONE: "${config.timezone}" (Beispiel: Europe/Berlin)`);
  }
  return config;
}
