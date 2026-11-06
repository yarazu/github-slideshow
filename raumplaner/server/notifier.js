import { formatRange, formatTime, formatDate } from '../public/shared/time.js';
import { icsCalendar, icsEvent } from './ics.js';

function esc(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function emailAddress(from) {
  const m = /<([^>]+)>/.exec(from || '');
  return (m ? m[1] : from || '').trim();
}

/** Text- und HTML-Fassung einer Benachrichtigungs-E-Mail. */
const brandOf = (orgName) => (!orgName || orgName === 'Raumplaner' ? 'Raumplaner' : `${orgName} · Raumplaner`);

export function renderEmail({ orgName, heading, lines = [], details = [], button, footer }) {
  const text = [
    heading,
    '',
    ...lines,
    ...(details.length ? ['', ...details.map(([k, v]) => `${k}: ${v}`)] : []),
    ...(button ? ['', `${button.label}: ${button.url}`] : []),
    '',
    '--',
    footer,
  ].join('\n');

  const html = `<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"></head>
<body style="margin:0;padding:0;background:#f3f5f9;font-family:'Segoe UI',Arial,Helvetica,sans-serif;color:#1f2937">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f5f9;padding:24px 8px"><tr><td align="center">
<table role="presentation" width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;background:#ffffff;border-radius:12px;border:1px solid #e3e7ef">
<tr><td style="background:#1e4fd6;color:#ffffff;padding:14px 24px;font-size:14px;font-weight:600;border-radius:12px 12px 0 0">${esc(brandOf(orgName))}</td></tr>
<tr><td style="padding:24px">
<h1 style="margin:0 0 12px;font-size:20px;line-height:1.3;color:#111827">${esc(heading)}</h1>
${lines.map((l) => `<p style="margin:0 0 12px;line-height:1.55">${esc(l)}</p>`).join('\n')}
${
  details.length
    ? `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:12px 0;border-collapse:collapse;width:100%">${details
        .map(
          ([k, v]) =>
            `<tr><td style="padding:6px 16px 6px 0;color:#6b7280;white-space:nowrap;vertical-align:top;font-size:14px">${esc(k)}</td><td style="padding:6px 0;vertical-align:top;font-size:14px">${esc(v).replace(/\n/g, '<br>')}</td></tr>`,
        )
        .join('')}</table>`
    : ''
}
${
  button
    ? `<p style="margin:20px 0 4px"><a href="${esc(button.url)}" style="display:inline-block;background:#1e4fd6;color:#ffffff;text-decoration:none;padding:11px 18px;border-radius:8px;font-weight:600;font-size:14px">${esc(button.label)}</a></p>`
    : ''
}
</td></tr>
<tr><td style="padding:14px 24px;background:#f8fafc;color:#6b7280;font-size:12px;line-height:1.5;border-radius:0 0 12px 12px">${esc(footer)}</td></tr>
</table></td></tr></table></body></html>`;
  return { text, html };
}

/**
 * Verteilt Benachrichtigungen über alle Kanäle:
 *  1. In-App (Glocke) – wird immer gespeichert und live an offene Tabs gepusht,
 *  2. E-Mail (über die Outbox, mit Kalendereinladung im Anhang),
 *  3. Desktop-Benachrichtigung im Browser (ausgelöst durch das Live-Event).
 * Alle Methoden schreiben nur in die Datenbank und laufen innerhalb der Transaktion
 * der auslösenden Aktion – Live-Events werden erst nach dem COMMIT verschickt.
 */
export class Notifier {
  constructor({ db, hub, mailer, config, clock, settings }) {
    this.db = db;
    this.hub = hub;
    this.mailer = mailer;
    this.config = config;
    this.clock = clock;
    this.settings = settings;
    this.tz = config.timezone;
    this.host = new URL(config.publicUrl).hostname || 'raumplaner';
    this.organizerEmail = emailAddress(config.smtp.from) || `raumplaner@${this.host}`;
  }

  get orgName() {
    return this.settings.get('org_name');
  }

  link(hashPath) {
    return `${this.config.publicUrl}/${hashPath}`;
  }

  footer() {
    const org = this.orgName && this.orgName !== 'Raumplaner' ? ` (${this.orgName})` : '';
    return `Diese Nachricht wurde automatisch vom Raumplaner${org} verschickt. Benachrichtigungen und Erinnerungen kannst du in deinem Profil einstellen: ${this.link('#/profil')}`;
  }

  // ------------------------------------------------------------------ In-App

  push(userId, { type, title, body = '', link = null, bookingId = null }) {
    if (!userId) return null;
    const now = this.clock.now();
    const r = this.db.run(
      'INSERT INTO notifications (user_id, type, title, body, link, booking_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [userId, type, title, body, link, bookingId, now],
    );
    const id = r.lastInsertRowid;
    this.db.afterCommit(() => {
      this.hub.sendToUser(userId, 'notification', {
        id,
        type,
        title,
        body,
        link,
        bookingId,
        createdAt: now,
        unreadCount: this.unreadCount(userId),
      });
    });
    return id;
  }

  unreadCount(userId) {
    return this.db.get('SELECT COUNT(*) AS n FROM notifications WHERE user_id = ? AND read_at IS NULL', [userId]).n;
  }

  // ------------------------------------------------------------------ Helfer

  location(b) {
    return `${b.room_name} · ${b.floor_name} · ${b.building_name}`;
  }

  /** Buchender und Teilnehmende (ohne Duplikate, nur aktive Konten erhalten In-App-Nachrichten). */
  recipients(b) {
    const booker = {
      userId: b.user_active ? b.user_id : null,
      email: b.user_email,
      name: b.user_name,
      notifyEmail: Boolean(b.user_active && b.user_notify_email),
    };
    const seen = new Set([String(b.user_email).toLowerCase()]);
    const attendees = [];
    for (const a of b.attendees || []) {
      const key = a.email.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      attendees.push({
        userId: a.user_id || null,
        email: a.email,
        name: a.name || a.email,
        notifyEmail: a.user_id ? Boolean(a.notify_email) : true,
      });
    }
    return { booker, attendees };
  }

  icsLines(b, status) {
    const { booker, attendees } = this.recipients(b);
    const description = [
      b.description,
      `Gebucht von ${b.user_name} über den Raumplaner: ${this.link(`#/buchungen?id=${b.id}`)}`,
    ]
      .filter(Boolean)
      .join('\n\n');
    return icsEvent({
      uid: `booking-${b.id}@${this.host}`,
      sequence: b.sequence,
      start: b.start_ts,
      end: b.end_ts,
      stamp: this.clock.now(),
      summary: b.title,
      description,
      location: this.location(b),
      status,
      organizer: { name: brandOf(this.orgName), email: this.organizerEmail },
      attendees: [booker, ...attendees].map((p) => ({ name: p.name, email: p.email })),
    });
  }

  details(b, count) {
    const rows = [
      ['Termin', b.title],
      ['Wann', count > 1 ? `${count} Termine, erster: ${formatRange(b.start_ts, b.end_ts, this.tz)}` : formatRange(b.start_ts, b.end_ts, this.tz)],
      ['Raum', this.location(b)],
      ['Gebucht von', `${b.user_name} (${b.user_email})`],
    ];
    const others = this.recipients(b).attendees;
    if (others.length) rows.push(['Teilnehmende', others.map((a) => a.name).join(', ')]);
    if (b.description) rows.push(['Beschreibung', b.description]);
    return rows;
  }

  /** Verschickt eine E-Mail zu einer (Serien-)Buchung inkl. Kalenderdatei. */
  mailBooking({ to, kind, bookings, actor, reason, changes = [] }) {
    if (!to?.email || !to.notifyEmail) return;
    const b = bookings[0];
    const count = bookings.length;
    const short = `${b.room_name}, ${formatDate(b.start_ts, this.tz)} ${formatTime(b.start_ts, this.tz)}`;
    const actorName = actor?.name || 'Raumplaner';
    let subject;
    let heading;
    const lines = [];
    let icsStatus = 'CONFIRMED';
    let method = 'REQUEST';

    switch (kind) {
      case 'confirmed':
        subject = `Buchung bestätigt: ${b.title} – ${short}`;
        heading = count > 1 ? `Deine Serienbuchung ist bestätigt (${count} Termine)` : 'Deine Buchung ist bestätigt';
        lines.push(`Hallo ${to.name}, der Raum ist für dich reserviert.`);
        break;
      case 'invite':
        subject = `Einladung: ${b.title} – ${short}`;
        heading = `${b.user_name} hat dich eingeladen`;
        lines.push(`Hallo ${to.name}, du wurdest zu folgendem Termin eingeladen.`);
        break;
      case 'updated':
        subject = `Geändert: ${b.title} – ${short}`;
        heading = 'Ein Termin wurde geändert';
        lines.push(`Hallo ${to.name}, ${actorName} hat den Termin geändert.`);
        for (const [label, value] of changes) lines.push(`${label}: ${value}`);
        break;
      case 'cancelled':
        subject = `Abgesagt: ${b.title} – ${short}`;
        heading = count > 1 ? `${count} Termine wurden abgesagt` : 'Ein Termin wurde abgesagt';
        lines.push(`Hallo ${to.name}, ${actorName} hat den Termin storniert. Der Raum ist wieder frei.`);
        if (reason) lines.push(`Grund: ${reason}`);
        icsStatus = 'CANCELLED';
        method = 'CANCEL';
        break;
      case 'removed':
        subject = `Ausgeladen: ${b.title} – ${short}`;
        heading = 'Du nimmst an einem Termin nicht mehr teil';
        lines.push(`Hallo ${to.name}, ${actorName} hat dich aus dem Termin entfernt.`);
        icsStatus = 'CANCELLED';
        method = 'CANCEL';
        break;
      default:
        throw new Error(`Unbekannte E-Mail-Art: ${kind}`);
    }

    if (count > 1) {
      lines.push('Alle Termine:');
      lines.push(bookings.map((x) => `• ${formatRange(x.start_ts, x.end_ts, this.tz)}`).join('\n'));
    }

    const { text, html } = renderEmail({
      orgName: this.orgName,
      heading,
      lines,
      details: this.details(b, count),
      button: kind === 'cancelled' || kind === 'removed' ? { label: 'Raumplaner öffnen', url: this.link('#/') } : { label: 'Buchung ansehen', url: this.link(`#/buchungen?id=${b.id}`) },
      footer: this.footer(),
    });

    if (count === 1) {
      const ics = icsCalendar({ method, events: [this.icsLines(b, icsStatus)] });
      this.mailer.enqueue({ to: to.email, subject, text, html, ics, icsMethod: method });
    } else {
      const seriesMethod = method === 'CANCEL' ? 'CANCEL' : 'PUBLISH';
      const ics = icsCalendar({ method: seriesMethod, events: bookings.map((x) => this.icsLines(x, icsStatus)) });
      this.mailer.enqueue({
        to: to.email,
        subject,
        text,
        html,
        attachments: [
          {
            filename: method === 'CANCEL' ? 'absagen.ics' : 'termine.ics',
            content: ics,
            contentType: `text/calendar; charset=utf-8; method=${seriesMethod}`,
          },
        ],
      });
    }
  }

  // ------------------------------------------------------------------ Ereignisse

  /** Neue Buchung(en) – `bookings` sind alle Termine einer Serie (oder ein einzelner). */
  onCreated(bookings, actor) {
    const b = bookings[0];
    if (!b || b.type !== 'booking') return;
    const { booker, attendees } = this.recipients(b);
    const when =
      bookings.length > 1
        ? `${bookings.length} Termine ab ${formatRange(b.start_ts, b.end_ts, this.tz)}`
        : formatRange(b.start_ts, b.end_ts, this.tz);

    this.mailBooking({ to: booker, kind: 'confirmed', bookings, actor });
    for (const a of attendees) {
      if (a.userId) {
        this.push(a.userId, {
          type: 'invite',
          title: `Einladung: ${b.title}`,
          body: `${b.user_name} hat dich eingeladen – ${when} · ${this.location(b)}`,
          link: `#/buchungen?id=${b.id}`,
          bookingId: b.id,
        });
      }
      this.mailBooking({ to: a, kind: 'invite', bookings, actor });
    }
  }

  onUpdated(after, before, actor, { addedEmails = [], removedAttendees = [] } = {}) {
    if (after.type !== 'booking') return;
    const changes = [];
    if (before.start_ts !== after.start_ts || before.end_ts !== after.end_ts) {
      changes.push(['Neue Zeit', `${formatRange(after.start_ts, after.end_ts, this.tz)} (vorher: ${formatRange(before.start_ts, before.end_ts, this.tz)})`]);
    }
    if (before.room_id !== after.room_id) changes.push(['Neuer Raum', `${this.location(after)} (vorher: ${before.room_name})`]);
    if (before.title !== after.title) changes.push(['Neuer Titel', `${after.title} (vorher: ${before.title})`]);
    const significant = changes.length > 0 || before.description !== after.description;

    const { booker, attendees } = this.recipients(after);
    const actorIsBooker = actor?.id === after.user_id;
    const summary = changes.map(([k, v]) => `${k}: ${v}`).join(' · ') || 'Details wurden aktualisiert.';

    if (significant) {
      if (!actorIsBooker) {
        this.push(booker.userId, {
          type: 'updated',
          title: `Deine Buchung wurde geändert: ${after.title}`,
          body: `${actor?.name || 'Administration'}: ${summary}`,
          link: `#/buchungen?id=${after.id}`,
          bookingId: after.id,
        });
      }
      this.mailBooking({ to: booker, kind: 'updated', bookings: [after], actor, changes });
    }

    const added = new Set(addedEmails.map((e) => e.toLowerCase()));
    for (const a of attendees) {
      if (added.has(a.email.toLowerCase())) {
        if (a.userId) {
          this.push(a.userId, {
            type: 'invite',
            title: `Einladung: ${after.title}`,
            body: `${after.user_name} hat dich eingeladen – ${formatRange(after.start_ts, after.end_ts, this.tz)} · ${this.location(after)}`,
            link: `#/buchungen?id=${after.id}`,
            bookingId: after.id,
          });
        }
        this.mailBooking({ to: a, kind: 'invite', bookings: [after], actor });
      } else if (significant) {
        if (a.userId) {
          this.push(a.userId, {
            type: 'updated',
            title: `Termin geändert: ${after.title}`,
            body: summary,
            link: `#/buchungen?id=${after.id}`,
            bookingId: after.id,
          });
        }
        this.mailBooking({ to: a, kind: 'updated', bookings: [after], actor, changes });
      }
    }

    for (const r of removedAttendees) {
      const person = { userId: r.user_id || null, email: r.email, name: r.name || r.email, notifyEmail: r.user_id ? Boolean(r.notify_email) : true };
      if (person.email.toLowerCase() === String(after.user_email).toLowerCase()) continue;
      if (person.userId) {
        this.push(person.userId, {
          type: 'cancelled',
          title: `Ausgeladen: ${before.title}`,
          body: `${actor?.name || 'Jemand'} hat dich aus dem Termin am ${formatRange(before.start_ts, before.end_ts, this.tz)} entfernt.`,
          bookingId: before.id,
        });
      }
      this.mailBooking({ to: person, kind: 'removed', bookings: [{ ...before, sequence: after.sequence }], actor });
    }
  }

  /** Stornierte Buchungen – werden pro Serie bzw. Einzeltermin gebündelt benachrichtigt. */
  onCancelled(rows, actor, reason) {
    const groups = new Map();
    for (const r of rows) {
      if (r.type !== 'booking') continue;
      const key = r.series_id ? `s:${r.series_id}` : `b:${r.id}`;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(r);
    }
    for (const group of groups.values()) {
      group.sort((a, b) => a.start_ts - b.start_ts);
      const b = group[0];
      const { booker, attendees } = this.recipients(b);
      const actorIsBooker = actor?.id === b.user_id;
      const when =
        group.length > 1
          ? `${group.length} Termine ab ${formatRange(b.start_ts, b.end_ts, this.tz)}`
          : formatRange(b.start_ts, b.end_ts, this.tz);
      const by = actor?.name ? ` (durch ${actor.name})` : '';
      const why = reason ? ` Grund: ${reason}.` : '';

      if (!actorIsBooker) {
        this.push(booker.userId, {
          type: 'cancelled',
          title: `Deine Buchung wurde storniert: ${b.title}`,
          body: `${when} · ${this.location(b)}${by}.${why}`,
          bookingId: b.id,
        });
      }
      this.mailBooking({ to: booker, kind: 'cancelled', bookings: group, actor, reason });

      for (const a of attendees) {
        if (actor?.email && a.email.toLowerCase() === actor.email.toLowerCase()) continue;
        if (a.userId) {
          this.push(a.userId, {
            type: 'cancelled',
            title: `Abgesagt: ${b.title}`,
            body: `${when} · ${this.location(b)}${by}.${why}`,
            bookingId: b.id,
          });
        }
        this.mailBooking({ to: a, kind: 'cancelled', bookings: group, actor, reason });
      }
    }
  }

  /** Erinnerung kurz vor Beginn. */
  onReminder(b, user) {
    const minutes = Math.max(0, Math.round((b.start_ts - this.clock.now()) / 60000));
    const starts = minutes <= 1 ? 'beginnt jetzt' : `beginnt in ${minutes} Minuten`;
    const title = `Erinnerung: ${b.title} ${starts}`;
    const body = `${formatRange(b.start_ts, b.end_ts, this.tz)} · ${this.location(b)}`;
    this.push(user.id, { type: 'reminder', title, body, link: `#/buchungen?id=${b.id}`, bookingId: b.id });
    if (user.notify_email) {
      const { text, html } = renderEmail({
        orgName: this.orgName,
        heading: `${b.title} ${starts}`,
        lines: [`Hallo ${user.name}, kurze Erinnerung an deinen Termin um ${formatTime(b.start_ts, this.tz)} Uhr.`],
        details: this.details(b, 1),
        button: { label: 'Buchung ansehen', url: this.link(`#/buchungen?id=${b.id}`) },
        footer: this.footer(),
      });
      this.mailer.enqueue({
        to: user.email,
        subject: `Erinnerung: ${b.title} um ${formatTime(b.start_ts, this.tz)} Uhr – ${b.room_name}`,
        text,
        html,
      });
    }
  }

  /** Ein gewünschter Raum ist frei geworden. */
  onWatchFree(watch, room, user) {
    const when = formatRange(watch.start_ts, watch.end_ts, this.tz);
    const link = `#/buchen?room=${room.id}&start=${watch.start_ts}&end=${watch.end_ts}`;
    const location = `${room.name} · ${room.floor_name} · ${room.building_name}`;
    this.push(user.id, {
      type: 'watch',
      title: `Raum frei: ${room.name}`,
      body: `${when} ist ${room.name} jetzt frei – schnell buchen, bevor es jemand anderes tut.`,
      link,
    });
    if (user.notify_email) {
      const { text, html } = renderEmail({
        orgName: this.orgName,
        heading: `${room.name} ist jetzt frei`,
        lines: [`Hallo ${user.name}, der Raum, den du dir gewünscht hast, ist im gewünschten Zeitraum frei geworden.`],
        details: [
          ['Raum', location],
          ['Wann', when],
        ],
        button: { label: 'Jetzt buchen', url: this.link(link) },
        footer: this.footer(),
      });
      this.mailer.enqueue({ to: user.email, subject: `Raum frei: ${room.name} – ${when}`, text, html });
    }
  }

  /** Testnachricht aus dem Profil – prüft alle Kanäle. */
  onTest(user) {
    this.push(user.id, {
      type: 'test',
      title: 'Test-Benachrichtigung',
      body: 'Wenn du das liest, funktionieren deine Benachrichtigungen.',
      link: '#/benachrichtigungen',
    });
    let email = false;
    if (this.mailer.enabled) {
      const { text, html } = renderEmail({
        orgName: this.orgName,
        heading: 'Test-Benachrichtigung',
        lines: [`Hallo ${user.name}, wenn du diese E-Mail erhältst, kommen Benachrichtigungen des Raumplaners bei dir an.`],
        button: { label: 'Raumplaner öffnen', url: this.link('#/') },
        footer: this.footer(),
      });
      this.mailer.enqueue({ to: user.email, subject: 'Raumplaner: Test-Benachrichtigung', text, html });
      email = true;
    }
    return { inApp: true, email };
  }
}
