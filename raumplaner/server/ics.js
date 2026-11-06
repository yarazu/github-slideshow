/**
 * iCalendar (RFC 5545) – für Einladungen/Absagen per E-Mail und das Kalender-Abo.
 * Alle Zeiten werden in UTC geschrieben; Outlook, Google & Co. rechnen sie selbst um.
 */
const CRLF = '\r\n';

function escapeText(value) {
  return String(value ?? '')
    .replace(/\\/g, '\\\\')
    .replace(/;/g, '\\;')
    .replace(/,/g, '\\,')
    .replace(/\r?\n/g, '\\n');
}

function paramValue(value) {
  // Parameterwerte (z. B. CN) dürfen keine Anführungszeichen/Steuerzeichen enthalten.
  return `"${String(value ?? '').replace(/["\r\n]/g, '')}"`;
}

/** Zeilen auf max. 75 Oktette falten (UTF-8-sicher, Fortsetzungszeilen beginnen mit Leerzeichen). */
function fold(line) {
  if (Buffer.byteLength(line, 'utf8') <= 75) return line;
  const parts = [];
  let current = '';
  let bytes = 0;
  let limit = 75;
  for (const ch of line) {
    const b = Buffer.byteLength(ch, 'utf8');
    if (bytes + b > limit) {
      parts.push(current);
      current = '';
      bytes = 0;
      limit = 74;
    }
    current += ch;
    bytes += b;
  }
  parts.push(current);
  return parts.join(`${CRLF} `);
}

export function icsDate(ms) {
  return new Date(ms).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
}

/**
 * @param {object} ev
 * @param {string} ev.uid
 * @param {number} ev.sequence
 * @param {number} ev.start
 * @param {number} ev.end
 * @param {number} ev.stamp
 * @param {string} ev.summary
 * @param {string} [ev.description]
 * @param {string} [ev.location]
 * @param {'CONFIRMED'|'CANCELLED'} [ev.status]
 * @param {{name:string,email:string}} [ev.organizer]
 * @param {{name?:string,email:string}[]} [ev.attendees]
 * @param {string} [ev.url]
 */
export function icsEvent(ev) {
  const lines = [
    'BEGIN:VEVENT',
    `UID:${ev.uid}`,
    `SEQUENCE:${ev.sequence ?? 0}`,
    `DTSTAMP:${icsDate(ev.stamp ?? Date.now())}`,
    `DTSTART:${icsDate(ev.start)}`,
    `DTEND:${icsDate(ev.end)}`,
    `SUMMARY:${escapeText(ev.summary)}`,
  ];
  if (ev.location) lines.push(`LOCATION:${escapeText(ev.location)}`);
  if (ev.description) lines.push(`DESCRIPTION:${escapeText(ev.description)}`);
  if (ev.url) lines.push(`URL:${ev.url}`);
  lines.push(`STATUS:${ev.status || 'CONFIRMED'}`);
  lines.push('TRANSP:OPAQUE');
  if (ev.organizer?.email) {
    lines.push(`ORGANIZER;CN=${paramValue(ev.organizer.name || ev.organizer.email)}:mailto:${ev.organizer.email}`);
  }
  for (const a of ev.attendees || []) {
    lines.push(
      `ATTENDEE;CN=${paramValue(a.name || a.email)};ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=FALSE:mailto:${a.email}`,
    );
  }
  lines.push('END:VEVENT');
  return lines;
}

export function icsCalendar({ method, events, name }) {
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Raumplaner//DE', 'CALSCALE:GREGORIAN'];
  if (method) lines.push(`METHOD:${method}`);
  if (name) {
    lines.push(`X-WR-CALNAME:${escapeText(name)}`);
    lines.push('X-PUBLISHED-TTL:PT15M');
    lines.push('REFRESH-INTERVAL;VALUE=DURATION:PT15M');
  }
  for (const ev of events) lines.push(...ev);
  lines.push('END:VCALENDAR');
  return lines.map(fold).join(CRLF) + CRLF;
}
