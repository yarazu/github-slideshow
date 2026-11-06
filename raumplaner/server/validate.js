import { badRequest } from './errors.js';

const EMAIL_RE = /^[^\s@<>()[\]\\,;:"]+@[^\s@<>()[\]\\,;:"]+\.[^\s@<>()[\]\\,;:"]{2,}$/;

// Steuerzeichen (außer Zeilenumbruch/Tab) entfernen – verhindert kaputte E-Mails/ICS-Dateien.
// eslint-disable-next-line no-control-regex
const CONTROL_RE = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g;

function clean(value) {
  return String(value).replace(CONTROL_RE, '').trim();
}

export function reqString(value, field, { max = 200 } = {}) {
  if (value === undefined || value === null) throw badRequest(`${field} fehlt.`);
  const s = clean(value);
  if (!s) throw badRequest(`${field} darf nicht leer sein.`);
  if (s.length > max) throw badRequest(`${field} ist zu lang (max. ${max} Zeichen).`);
  return s;
}

export function optString(value, field, { max = 2000 } = {}) {
  if (value === undefined || value === null) return '';
  const s = clean(value);
  if (s.length > max) throw badRequest(`${field} ist zu lang (max. ${max} Zeichen).`);
  return s;
}

export function toInt(value, field, { min = -Infinity, max = Infinity, def } = {}) {
  if (value === undefined || value === null || value === '') {
    if (def !== undefined) return def;
    throw badRequest(`${field} fehlt.`);
  }
  const n = Number(value);
  if (!Number.isInteger(n)) throw badRequest(`${field} muss eine ganze Zahl sein.`);
  if (n < min || n > max) throw badRequest(`${field} muss zwischen ${min} und ${max} liegen.`);
  return n;
}

export function toNumber(value, field, { min = -Infinity, max = Infinity } = {}) {
  const n = Number(value);
  if (!Number.isFinite(n)) throw badRequest(`${field} muss eine Zahl sein.`);
  if (n < min || n > max) throw badRequest(`${field} liegt außerhalb des erlaubten Bereichs.`);
  return n;
}

export function toBool(value, def = false) {
  if (value === undefined || value === null || value === '') return def;
  if (typeof value === 'boolean') return value;
  return ['1', 'true', 'yes', 'on', 'ja'].includes(String(value).toLowerCase());
}

export function isEmail(value) {
  return typeof value === 'string' && value.length <= 254 && EMAIL_RE.test(value);
}

export function reqEmail(value, field = 'E-Mail-Adresse') {
  const s = clean(value ?? '').toLowerCase();
  if (!isEmail(s)) throw badRequest(`${field} ist ungültig.`);
  return s;
}

export function toId(value, field = 'ID') {
  const n = Number(value);
  if (!Number.isInteger(n) || n <= 0) throw badRequest(`${field} ist ungültig.`);
  return n;
}

/** Akzeptiert Epoch-Millisekunden oder einen ISO-8601-Zeitstempel. */
export function toTimestamp(value, field) {
  if (value === undefined || value === null || value === '') throw badRequest(`${field} fehlt.`);
  const n = typeof value === 'number' ? value : /^\d+$/.test(String(value)) ? Number(value) : Date.parse(value);
  if (!Number.isFinite(n)) throw badRequest(`${field} ist kein gültiger Zeitpunkt.`);
  return Math.round(n);
}

export function password(value) {
  if (typeof value !== 'string' || value.length < 8) {
    throw badRequest('Das Passwort muss mindestens 8 Zeichen lang sein.');
  }
  if (value.length > 200) throw badRequest('Das Passwort ist zu lang.');
  return value;
}
