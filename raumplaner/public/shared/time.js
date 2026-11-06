/**
 * Zeit-Hilfsfunktionen – gemeinsam genutzt von Server (Node.js) und Browser.
 *
 * Alle Zeitpunkte sind Epoch-Millisekunden (UTC). Wanduhrzeiten (Datum + Uhrzeit)
 * werden immer in EINER festen IANA-Zeitzone interpretiert (z. B. "Europe/Berlin").
 * So sehen alle Nutzer dieselben Zeiten – unabhängig von der Zeitzone ihres Geräts –
 * und Serientermine bleiben über die Sommer-/Winterzeit-Umstellung auf derselben Uhrzeit.
 */

const pad = (n) => String(n).padStart(2, '0');

const partsFormatters = new Map();
function partsFormatter(tz) {
  let f = partsFormatters.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone: tz,
      hourCycle: 'h23',
      year: 'numeric',
      month: 'numeric',
      day: 'numeric',
      hour: 'numeric',
      minute: 'numeric',
      second: 'numeric',
    });
    partsFormatters.set(tz, f);
  }
  return f;
}

/** Prüft, ob eine Zeitzone gültig ist. */
export function isValidTimezone(tz) {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

/** Zerlegt einen Zeitpunkt in die Wanduhr-Komponenten der Zeitzone (Monat 1–12). */
export function zonedParts(ms, tz) {
  const out = {};
  for (const p of partsFormatter(tz).formatToParts(new Date(ms))) {
    if (p.type !== 'literal') out[p.type] = Number(p.value);
  }
  if (out.hour === 24) out.hour = 0;
  return {
    year: out.year,
    month: out.month,
    day: out.day,
    hour: out.hour,
    minute: out.minute,
    second: out.second,
  };
}

function offsetAt(ms, tz) {
  const p = zonedParts(ms, tz);
  const asUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  return asUtc - Math.floor(ms / 1000) * 1000;
}

/**
 * Wanduhrzeit in der Zeitzone -> Epoch-ms.
 * Monat 1–12; Überläufe (z. B. Tag 32) werden wie bei Date.UTC normalisiert.
 */
export function zonedToUtc(year, month, day, hour, minute, tz) {
  const guess = Date.UTC(year, month - 1, day, hour, minute);
  const first = offsetAt(guess, tz);
  let ms = guess - first;
  const second = offsetAt(ms, tz);
  if (second !== first) ms = guess - second;
  return ms;
}

/** "YYYY-MM-DD" des Zeitpunkts in der Zeitzone. */
export function dateKey(ms, tz) {
  const p = zonedParts(ms, tz);
  return `${p.year}-${pad(p.month)}-${pad(p.day)}`;
}

/** "HH:MM" des Zeitpunkts in der Zeitzone. */
export function timeKey(ms, tz) {
  const p = zonedParts(ms, tz);
  return `${pad(p.hour)}:${pad(p.minute)}`;
}

/** Minuten seit Mitternacht (Wanduhr) des Zeitpunkts. */
export function minutesOfDay(ms, tz) {
  const p = zonedParts(ms, tz);
  return p.hour * 60 + p.minute;
}

export function parseDateKey(key) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(key ?? ''));
  if (!m) return null;
  const year = Number(m[1]);
  const month = Number(m[2]);
  const day = Number(m[3]);
  const check = new Date(Date.UTC(year, month - 1, day));
  if (check.getUTCFullYear() !== year || check.getUTCMonth() !== month - 1 || check.getUTCDate() !== day) {
    return null;
  }
  return { year, month, day };
}

export function parseTimeKey(key) {
  const m = /^(\d{1,2}):(\d{2})$/.exec(String(key ?? ''));
  if (!m) return null;
  const hour = Number(m[1]);
  const minute = Number(m[2]);
  if (hour > 24 || minute > 59 || (hour === 24 && minute !== 0)) return null;
  return { hour, minute };
}

/** "2026-11-12" + "10:30" (Wanduhr in tz) -> Epoch-ms. "24:00" bedeutet Mitternacht am Folgetag. */
export function fromLocal(dKey, tKey, tz) {
  const d = parseDateKey(dKey);
  const t = parseTimeKey(tKey);
  if (!d || !t) return NaN;
  return zonedToUtc(d.year, d.month, d.day, t.hour, t.minute, tz);
}

export function addDaysToKey(key, days) {
  const d = parseDateKey(key);
  if (!d) return null;
  const dt = new Date(Date.UTC(d.year, d.month - 1, d.day + days));
  return `${dt.getUTCFullYear()}-${pad(dt.getUTCMonth() + 1)}-${pad(dt.getUTCDate())}`;
}

/** Gleicher Tag im Monat, n Monate später. `valid` ist false, wenn es den Tag nicht gibt (z. B. 31.04.). */
function addMonthsToKey(key, months) {
  const d = parseDateKey(key);
  const total = d.month - 1 + months;
  const year = d.year + Math.floor(total / 12);
  const month = (((total % 12) + 12) % 12) + 1;
  const candidate = `${year}-${pad(month)}-${pad(d.day)}`;
  return { key: candidate, firstOfMonth: `${year}-${pad(month)}-01`, valid: parseDateKey(candidate) !== null };
}

/** Wochentag eines Datums: 0 = Sonntag … 6 = Samstag. */
export function weekdayOfKey(key) {
  const d = parseDateKey(key);
  return new Date(Date.UTC(d.year, d.month - 1, d.day)).getUTCDay();
}

/** Beginn und Ende (exklusiv) eines Kalendertages in der Zeitzone. */
export function dayBounds(key, tz) {
  return { start: fromLocal(key, '00:00', tz), end: fromLocal(addDaysToKey(key, 1), '00:00', tz) };
}

/** Rundet auf das nächste Raster (z. B. 15 Minuten) auf. */
export function ceilToSlot(ms, slotMinutes) {
  const step = slotMinutes * 60000;
  return Math.ceil(ms / step) * step;
}

/** Rundet auf das Raster ab. */
export function floorToSlot(ms, slotMinutes) {
  const step = slotMinutes * 60000;
  return Math.floor(ms / step) * step;
}

// ---------------------------------------------------------------------------
// Serientermine
// ---------------------------------------------------------------------------

export const MAX_OCCURRENCES = 100;

export const RECURRENCE_LABELS = {
  none: 'Keine',
  workdays: 'Werktäglich (Mo–Fr)',
  weekly: 'Wöchentlich',
  biweekly: 'Alle 2 Wochen',
  monthly: 'Monatlich (gleicher Tag)',
};

/**
 * Erzeugt alle Termine einer Serie. Der erste Termin ist immer der angegebene.
 * rule = { freq: 'workdays'|'weekly'|'biweekly'|'monthly', until: 'YYYY-MM-DD' }
 * Die Uhrzeit bleibt in der Zeitzone gleich (auch über Zeitumstellungen hinweg).
 */
export function expandRecurrence(start, end, rule, tz) {
  const occurrences = [{ start, end }];
  if (!rule || !rule.freq || rule.freq === 'none') return occurrences;
  if (!RECURRENCE_LABELS[rule.freq]) throw new Error(`Unbekannte Wiederholung: ${rule.freq}`);
  const until = parseDateKey(rule.until) ? rule.until : null;
  if (!until) throw new Error('Für Serientermine wird ein Enddatum benötigt.');

  const startKey = dateKey(start, tz);
  const { hour, minute } = zonedParts(start, tz);
  const duration = end - start;
  const at = (key) => {
    const d = parseDateKey(key);
    const s = zonedToUtc(d.year, d.month, d.day, hour, minute, tz);
    return { start: s, end: s + duration };
  };

  for (let i = 1; i < 4000 && occurrences.length < MAX_OCCURRENCES; i++) {
    let key;
    if (rule.freq === 'workdays') key = addDaysToKey(startKey, i);
    else if (rule.freq === 'weekly') key = addDaysToKey(startKey, 7 * i);
    else if (rule.freq === 'biweekly') key = addDaysToKey(startKey, 14 * i);
    else {
      const m = addMonthsToKey(startKey, i);
      if (!m.valid) {
        if (m.firstOfMonth > until) break;
        continue;
      }
      key = m.key;
    }
    if (key > until) break;
    if (rule.freq === 'workdays') {
      const wd = weekdayOfKey(key);
      if (wd === 0 || wd === 6) continue;
    }
    occurrences.push(at(key));
  }
  return occurrences;
}

// ---------------------------------------------------------------------------
// Formatierung (deutsch)
// ---------------------------------------------------------------------------

const formatters = new Map();
function fmt(tz, opts) {
  const k = tz + JSON.stringify(opts);
  let f = formatters.get(k);
  if (!f) {
    f = new Intl.DateTimeFormat('de-DE', { timeZone: tz, ...opts });
    formatters.set(k, f);
  }
  return f;
}

/** "10:00" */
export function formatTime(ms, tz) {
  return fmt(tz, { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(ms);
}

/** "Do., 12.11.2026" */
export function formatDate(ms, tz) {
  return fmt(tz, { weekday: 'short', day: '2-digit', month: '2-digit', year: 'numeric' }).format(ms);
}

/** "Donnerstag, 12. November 2026" */
export function formatDateLong(ms, tz) {
  return fmt(tz, { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }).format(ms);
}

/** "12.11.2026, 10:00" */
export function formatDateTime(ms, tz) {
  return `${fmt(tz, { day: '2-digit', month: '2-digit', year: 'numeric' }).format(ms)}, ${formatTime(ms, tz)}`;
}

/** "Do., 12.11.2026, 10:00–11:00 Uhr" bzw. über mehrere Tage ausgeschrieben. */
export function formatRange(start, end, tz) {
  const sameDay = dateKey(start, tz) === dateKey(end - 1, tz);
  if (sameDay) {
    const endLabel = timeKey(end, tz) === '00:00' ? '24:00' : formatTime(end, tz);
    return `${formatDate(start, tz)}, ${formatTime(start, tz)}–${endLabel} Uhr`;
  }
  return `${formatDate(start, tz)}, ${formatTime(start, tz)} Uhr – ${formatDate(end, tz)}, ${formatTime(end, tz)} Uhr`;
}

/** "1 Std. 30 Min." */
export function formatDuration(ms) {
  const total = Math.round(ms / 60000);
  const h = Math.floor(total / 60);
  const m = total % 60;
  if (h && m) return `${h} Std. ${m} Min.`;
  if (h) return `${h} Std.`;
  return `${m} Min.`;
}
