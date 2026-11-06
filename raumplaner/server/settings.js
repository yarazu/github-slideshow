import { badRequest } from './errors.js';

/** Standardwerte – können von Administratoren in der Oberfläche geändert werden. */
export const DEFAULT_SETTINGS = {
  org_name: 'Raumplaner',
  day_start_hour: 7,
  day_end_hour: 20,
  slot_minutes: 15,
  max_booking_minutes: 600,
  max_days_ahead: 365,
  allow_registration: true,
  allowed_email_domains: '',
  equipment_options: ['Beamer', 'Bildschirm', 'Videokonferenz', 'Whiteboard', 'Flipchart', 'Telefon', 'Barrierefrei'],
  default_reminder_minutes: 15,
};

const RULES = {
  org_name: (v) => {
    const s = String(v ?? '').trim();
    if (!s || s.length > 80) throw badRequest('Der Name der Organisation muss 1–80 Zeichen haben.');
    return s;
  },
  day_start_hour: (v) => intIn(v, 0, 23, 'Tagesbeginn'),
  day_end_hour: (v) => intIn(v, 1, 24, 'Tagesende'),
  slot_minutes: (v) => {
    const n = Number(v);
    if (![5, 10, 15, 30, 60].includes(n)) throw badRequest('Das Zeitraster muss 5, 10, 15, 30 oder 60 Minuten sein.');
    return n;
  },
  max_booking_minutes: (v) => intIn(v, 15, 7 * 24 * 60, 'Maximale Buchungsdauer'),
  max_days_ahead: (v) => intIn(v, 1, 1095, 'Vorausbuchung'),
  allow_registration: (v) => v === true || v === 'true' || v === 1,
  allowed_email_domains: (v) => {
    const domains = String(v ?? '')
      .split(/[\s,;]+/)
      .map((d) => d.trim().toLowerCase().replace(/^@/, ''))
      .filter(Boolean);
    for (const d of domains) {
      if (!/^[a-z0-9.-]+\.[a-z]{2,}$/.test(d)) throw badRequest(`Ungültige Domain: ${d}`);
    }
    return domains.join(', ');
  },
  equipment_options: (v) => {
    const list = (Array.isArray(v) ? v : String(v ?? '').split(','))
      .map((s) => String(s).trim())
      .filter(Boolean);
    const unique = [...new Set(list)];
    if (unique.length > 40) throw badRequest('Maximal 40 Ausstattungsmerkmale.');
    for (const item of unique) if (item.length > 40) throw badRequest(`Ausstattung zu lang: ${item}`);
    return unique;
  },
  default_reminder_minutes: (v) => intIn(v, 0, 1440, 'Standard-Erinnerung'),
};

/** Prüft und übernimmt Änderungen an den Einstellungen (rein, ohne Datenbank – auch im Browser nutzbar). */
export function normalizeSettings(patch, current) {
  const next = { ...current };
  for (const [key, value] of Object.entries(patch || {})) {
    if (!(key in RULES)) continue;
    next[key] = RULES[key](value);
  }
  if (next.day_end_hour <= next.day_start_hour) {
    throw badRequest('Das Tagesende muss nach dem Tagesbeginn liegen.');
  }
  return next;
}

function intIn(v, min, max, label) {
  const n = Number(v);
  if (!Number.isInteger(n) || n < min || n > max) throw badRequest(`${label} muss zwischen ${min} und ${max} liegen.`);
  return n;
}

export class Settings {
  constructor({ db }) {
    this.db = db;
    this.cache = null;
  }

  all() {
    if (!this.cache) {
      const values = { ...DEFAULT_SETTINGS };
      for (const row of this.db.all('SELECT key, value FROM settings')) {
        if (row.key in DEFAULT_SETTINGS) {
          try {
            values[row.key] = JSON.parse(row.value);
          } catch {
            /* defekter Wert – Standard behalten */
          }
        }
      }
      this.cache = values;
    }
    return this.cache;
  }

  get(key) {
    return this.all()[key];
  }

  update(patch) {
    const next = normalizeSettings(patch, this.all());
    this.db.tx(() => {
      for (const key of Object.keys(RULES)) {
        this.db.run('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value', [
          key,
          JSON.stringify(next[key]),
        ]);
      }
    });
    this.cache = null;
    return this.all();
  }

  /** Prüft, ob eine E-Mail-Domain für die Selbstregistrierung erlaubt ist. */
  emailDomainAllowed(email) {
    const allowed = String(this.get('allowed_email_domains') || '')
      .split(',')
      .map((d) => d.trim())
      .filter(Boolean);
    if (!allowed.length) return true;
    const domain = email.split('@')[1]?.toLowerCase();
    return allowed.includes(domain);
  }
}
