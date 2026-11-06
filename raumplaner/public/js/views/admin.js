import { del, get, post, put } from '../api.js';
import { fmt, loadLayout, roomsOfFloor, sortedFloors, state } from '../state.js';
import { confirmDialog, emptyState, field, h, icon, openDialog, promptDialog, relativeTime, setBusy, toast, toastError } from '../ui.js';

const TABS = [
  ['gebaeude', 'Gebäude & Pläne', 'layers'],
  ['benutzer', 'Benutzer', 'users'],
  ['einstellungen', 'Einstellungen', 'sliders'],
  ['system', 'System & E-Mail', 'database'],
  ['protokoll', 'Protokoll', 'list'],
];

const HOSTED_TABS = [
  ['gebaeude', 'Gebäude & Pläne', 'layers'],
  ['benutzer', 'Personen', 'users'],
  ['einstellungen', 'Einstellungen', 'sliders'],
  ['system', 'Daten', 'database'],
  ['protokoll', 'Protokoll', 'list'],
];

export async function renderAdmin(root, { params }) {
  const tab = params[0] || 'gebaeude';
  root.append(
    h('div', { class: 'page-head' }, h('div', null, h('h1', null, 'Verwaltung'), h('p', null, 'Gebäude, Lagepläne, Benutzer und Systemzustand.'))),
    h(
      'nav',
      { class: 'tabs', 'aria-label': 'Verwaltung' },
      (state.hosted ? HOSTED_TABS : TABS).map(([key, label, ic]) => h('a', { href: `#/admin/${key}`, class: key === tab ? 'active' : '' }, icon(ic), ' ', label)),
    ),
  );
  const body = h('div', { class: 'stack' });
  root.append(body);
  const views = state.hosted
    ? { gebaeude: renderBuildings, benutzer: renderPeopleHosted, einstellungen: renderSettings, system: renderDataHosted, protokoll: renderAudit }
    : { gebaeude: renderBuildings, benutzer: renderUsers, einstellungen: renderSettings, system: renderSystem, protokoll: renderAudit };
  return views[tab](body);
}

// ------------------------------------------------------------------ Gebäude & Etagen

function buildingDialog(building, onDone) {
  const name = h('input', { class: 'input', value: building?.name || '', placeholder: 'z. B. Hauptgebäude' });
  const address = h('input', { class: 'input', value: building?.address || '', placeholder: 'Optional' });
  const err = h('div', { class: 'form-error' });
  const save = async () => {
    try {
      const body = { name: name.value, address: address.value };
      const res = building ? await put(`/api/buildings/${building.id}`, body) : await post('/api/buildings', body);
      d.close();
      onDone(res);
    } catch (e) {
      err.textContent = e.message;
    }
  };
  const d = openDialog({
    title: building ? 'Gebäude bearbeiten' : 'Gebäude anlegen',
    content: h('form', { class: 'form', onSubmit: (e) => (e.preventDefault(), save()) }, field('Name', name), field('Adresse', address), err, h('button', { type: 'submit', hidden: true })),
    actions: [h('button', { class: 'btn', type: 'button', onClick: () => d.close() }, 'Abbrechen'), h('button', { class: 'btn btn-primary', type: 'button', onClick: save }, 'Speichern')],
  });
  setTimeout(() => name.focus(), 30);
}

export function floorDialog({ floor, buildingId }, onDone) {
  const name = h('input', { class: 'input', value: floor?.name || '', placeholder: 'z. B. Erdgeschoss, 1. OG' });
  const level = h('input', { class: 'input', type: 'number', value: floor?.level ?? 0 });
  const width = h('input', { class: 'input', type: 'number', min: 100, max: 10000, value: floor?.width ?? 1200 });
  const height = h('input', { class: 'input', type: 'number', min: 100, max: 10000, value: floor?.height ?? 800 });
  const err = h('div', { class: 'form-error' });
  const save = async () => {
    try {
      const body = { name: name.value, level: Number(level.value), width: Number(width.value), height: Number(height.value) };
      const res = floor ? await put(`/api/floors/${floor.id}`, body) : await post('/api/floors', { ...body, buildingId });
      d.close();
      onDone(res);
    } catch (e) {
      err.textContent = e.message;
    }
  };
  const d = openDialog({
    title: floor ? 'Etage bearbeiten' : 'Etage anlegen',
    content: h(
      'form',
      { class: 'form', onSubmit: (e) => (e.preventDefault(), save()) },
      field('Name', name),
      field('Ebene (Sortierung)', level, '0 = Erdgeschoss, 1 = 1. OG, -1 = Untergeschoss …'),
      h('div', { class: 'fields-2' }, field('Planbreite', width), field('Planhöhe', height)),
      h('p', { class: 'hint' }, 'Die Plangröße ist das Koordinatensystem zum Zeichnen. Beim Hochladen eines Grundrisses wird sie automatisch an das Bild angepasst.'),
      err,
      h('button', { type: 'submit', hidden: true }),
    ),
    actions: [h('button', { class: 'btn', type: 'button', onClick: () => d.close() }, 'Abbrechen'), h('button', { class: 'btn btn-primary', type: 'button', onClick: save }, 'Speichern')],
  });
  setTimeout(() => name.focus(), 30);
}

async function renderBuildings(body) {
  const render = async () => {
    await loadLayout();
    const { buildings } = state.layout;
    const floors = sortedFloors();
    body.replaceChildren();
    body.append(
      h(
        'div',
        { class: 'row-between' },
        h('p', { class: 'muted' }, 'Lege Gebäude und Etagen an und zeichne die Räume im Grundriss-Editor ein.'),
        h('button', { class: 'btn btn-primary', type: 'button', onClick: () => buildingDialog(null, render) }, icon('plus'), 'Gebäude anlegen'),
      ),
    );
    if (!buildings.length) {
      body.append(
        h(
          'div',
          { class: 'card' },
          emptyState('layers', 'Noch keine Gebäude', 'Starte mit einem eigenen Gebäude – oder lade ein Beispiel mit zwei Etagen, Besprechungsräumen und Arbeitsplätzen.', [
            h(
              'button',
              {
                class: 'btn',
                type: 'button',
                onClick: async (e) => {
                  setBusy(e.currentTarget, true);
                  try {
                    const res = await post('/api/admin/demo', { withBookings: true });
                    toast('Beispielgebäude geladen', { type: 'success', body: `${res.bookings} Beispielbuchungen angelegt.` });
                    render();
                  } catch (err) {
                    toastError(err);
                  }
                },
              },
              icon('download'),
              'Beispielgebäude laden',
            ),
            h('button', { class: 'btn btn-primary', type: 'button', onClick: () => buildingDialog(null, render) }, icon('plus'), 'Gebäude anlegen'),
          ]),
        ),
      );
      return;
    }
    for (const b of buildings) {
      const bFloors = floors.filter((f) => f.buildingId === b.id);
      body.append(
        h(
          'div',
          { class: 'card' },
          h(
            'div',
            { class: 'card-head' },
            h('div', null, h('h2', null, b.name), b.address ? h('div', { class: 'muted small' }, b.address) : null),
            h(
              'div',
              { class: 'row' },
              h('button', { class: 'btn btn-sm', type: 'button', onClick: () => floorDialog({ buildingId: b.id }, render) }, icon('plus'), 'Etage'),
              h('button', { class: 'btn btn-ghost btn-sm btn-icon', type: 'button', 'aria-label': 'Gebäude bearbeiten', onClick: () => buildingDialog(b, render) }, icon('edit')),
              h(
                'button',
                {
                  class: 'btn btn-ghost btn-sm btn-icon',
                  type: 'button',
                  'aria-label': 'Gebäude löschen',
                  onClick: async () => {
                    const ok = await confirmDialog(`„${b.name}“ mit allen Etagen und Räumen löschen?`, {
                      title: 'Gebäude löschen',
                      confirmLabel: 'Endgültig löschen',
                      danger: true,
                      details: 'Alle zukünftigen Buchungen in diesem Gebäude werden storniert und die Betroffenen benachrichtigt.',
                    });
                    if (!ok) return;
                    try {
                      const res = await del(`/api/buildings/${b.id}`);
                      toast('Gebäude gelöscht', { type: 'success', body: res.cancelledBookings ? `${res.cancelledBookings} Buchungen storniert.` : undefined });
                      render();
                    } catch (err) {
                      toastError(err);
                    }
                  },
                },
                icon('trash'),
              ),
            ),
          ),
          bFloors.length
            ? h(
                'ul',
                { class: 'list card-body flush' },
                bFloors.map((f) => {
                  const rooms = roomsOfFloor(f.id);
                  const bookable = rooms.filter((r) => r.kind !== 'area');
                  const unplaced = rooms.filter((r) => !r.shape).length;
                  return h(
                    'li',
                    { class: 'list-item' },
                    h(
                      'div',
                      { class: 'list-main' },
                      h('div', { class: 'list-title' }, f.name),
                      h(
                        'div',
                        { class: 'list-meta' },
                        h('span', null, `${bookable.filter((r) => r.kind === 'room').length} Räume`),
                        h('span', null, `${bookable.filter((r) => r.kind === 'desk').length} Arbeitsplätze`),
                        h('span', null, f.imageUrl ? 'Grundriss hinterlegt' : 'ohne Grundrissbild'),
                        unplaced ? h('span', { style: { color: 'var(--soon)' } }, `${unplaced} ohne Position`) : null,
                      ),
                    ),
                    h('a', { class: 'btn btn-sm btn-primary', href: `#/admin/etage/${f.id}` }, icon('edit'), 'Grundriss & Räume'),
                    h('button', { class: 'btn btn-ghost btn-sm btn-icon', type: 'button', 'aria-label': 'Etage bearbeiten', onClick: () => floorDialog({ floor: f }, render) }, icon('sliders')),
                    h(
                      'button',
                      {
                        class: 'btn btn-ghost btn-sm btn-icon',
                        type: 'button',
                        'aria-label': 'Etage löschen',
                        onClick: async () => {
                          const ok = await confirmDialog(`Etage „${f.name}“ mit ${rooms.length} Räumen/Bereichen löschen?`, {
                            title: 'Etage löschen',
                            confirmLabel: 'Endgültig löschen',
                            danger: true,
                            details: 'Zukünftige Buchungen werden storniert, die Betroffenen benachrichtigt.',
                          });
                          if (!ok) return;
                          try {
                            await del(`/api/floors/${f.id}`);
                            render();
                          } catch (err) {
                            toastError(err);
                          }
                        },
                      },
                      icon('trash'),
                    ),
                  );
                }),
              )
            : h('div', { class: 'card-body' }, h('p', { class: 'muted' }, 'Noch keine Etagen. Lege die erste Etage an, um Räume einzuzeichnen.')),
        ),
      );
    }
  };
  await render();
}

// ------------------------------------------------------------------ Benutzer

async function renderUsers(body) {
  const tableBody = h('tbody');
  const render = async () => {
    let users;
    try {
      users = await get('/api/admin/users');
    } catch (err) {
      tableBody.replaceChildren(h('tr', null, h('td', { colspan: 5 }, err.message)));
      return;
    }
    tableBody.replaceChildren(
      ...users.map((u) =>
        h(
          'tr',
          { style: u.active ? null : { opacity: '0.55' } },
          h('td', null, h('strong', null, u.name), u.id === state.me.id ? h('span', { class: 'badge primary', style: { marginLeft: '6px' } }, 'du') : null, h('div', { class: 'muted small' }, u.email)),
          h(
            'td',
            null,
            h(
              'select',
              {
                class: 'input',
                style: { width: 'auto' },
                'aria-label': `Rolle von ${u.name}`,
                onChange: async (e) => {
                  try {
                    await put(`/api/admin/users/${u.id}`, { role: e.target.value });
                    toast('Rolle geändert', { type: 'success', timeout: 2500 });
                  } catch (err) {
                    toastError(err);
                  }
                  render();
                },
              },
              h('option', { value: 'user', selected: u.role === 'user' }, 'Mitarbeiter/in'),
              h('option', { value: 'admin', selected: u.role === 'admin' }, 'Administration'),
            ),
          ),
          h('td', null, u.active ? h('span', { class: 'badge free' }, 'aktiv') : h('span', { class: 'badge' }, 'deaktiviert')),
          h('td', { class: 'small muted' }, u.lastLoginAt ? relativeTime(u.lastLoginAt) || fmt.dateTime(u.lastLoginAt) : 'nie'),
          h(
            'td',
            { class: 'nowrap', style: { textAlign: 'right' } },
            h(
              'button',
              {
                class: 'btn btn-ghost btn-sm',
                type: 'button',
                onClick: async () => {
                  const pw = await promptDialog(`Neues Passwort für ${u.name} festlegen. Teile es der Person auf sicherem Weg mit.`, {
                    title: 'Passwort zurücksetzen',
                    label: 'Neues Passwort (mind. 8 Zeichen)',
                    type: 'text',
                    confirmLabel: 'Passwort setzen',
                  });
                  if (pw === null) return;
                  try {
                    await post(`/api/admin/users/${u.id}/password`, { password: pw });
                    toast('Passwort gesetzt', { type: 'success', body: 'Alle Sitzungen der Person wurden abgemeldet.' });
                  } catch (err) {
                    toastError(err);
                  }
                },
              },
              'Passwort',
            ),
            h(
              'button',
              {
                class: 'btn btn-ghost btn-sm',
                type: 'button',
                onClick: async () => {
                  if (u.active) {
                    const ok = await confirmDialog(`${u.name} deaktivieren?`, {
                      title: 'Konto deaktivieren',
                      confirmLabel: 'Deaktivieren',
                      danger: true,
                      details: 'Die Person kann sich nicht mehr anmelden. Ihre zukünftigen Buchungen werden storniert, damit die Räume wieder frei sind; Teilnehmende werden benachrichtigt.',
                    });
                    if (!ok) return;
                  }
                  try {
                    const res = await put(`/api/admin/users/${u.id}`, { active: !u.active });
                    toast(u.active ? 'Konto deaktiviert' : 'Konto aktiviert', {
                      type: 'success',
                      body: res.cancelledBookings ? `${res.cancelledBookings} zukünftige Buchungen storniert.` : undefined,
                    });
                  } catch (err) {
                    toastError(err);
                  }
                  render();
                },
              },
              u.active ? 'Deaktivieren' : 'Aktivieren',
            ),
          ),
        ),
      ),
    );
  };

  const newUser = () => {
    const name = h('input', { class: 'input', autocomplete: 'off' });
    const email = h('input', { class: 'input', type: 'email', autocomplete: 'off' });
    const pw = h('input', { class: 'input', type: 'text', autocomplete: 'off' });
    const role = h('select', { class: 'input' }, h('option', { value: 'user' }, 'Mitarbeiter/in'), h('option', { value: 'admin' }, 'Administration'));
    const err = h('div', { class: 'form-error' });
    const save = async () => {
      try {
        await post('/api/admin/users', { name: name.value, email: email.value, password: pw.value, role: role.value });
        d.close();
        toast('Benutzer angelegt', { type: 'success', body: 'Teile die Zugangsdaten auf sicherem Weg mit.' });
        render();
      } catch (e) {
        err.textContent = e.message;
      }
    };
    const d = openDialog({
      title: 'Benutzer anlegen',
      content: h(
        'form',
        { class: 'form', onSubmit: (e) => (e.preventDefault(), save()) },
        field('Name', name),
        field('E-Mail-Adresse', email),
        field('Start-Passwort', pw, 'Mindestens 8 Zeichen. Die Person kann es im Profil ändern.'),
        field('Rolle', role),
        err,
        h('button', { type: 'submit', hidden: true }),
      ),
      actions: [h('button', { class: 'btn', type: 'button', onClick: () => d.close() }, 'Abbrechen'), h('button', { class: 'btn btn-primary', type: 'button', onClick: save }, 'Anlegen')],
    });
  };

  body.append(
    h(
      'div',
      { class: 'row-between' },
      h(
        'p',
        { class: 'muted' },
        state.config.allowRegistration
          ? `Selbstregistrierung ist erlaubt${state.config.allowedEmailDomains ? ` (nur ${state.config.allowedEmailDomains})` : ''}.`
          : 'Selbstregistrierung ist deaktiviert – lege Konten hier an.',
      ),
      h('button', { class: 'btn btn-primary', type: 'button', onClick: newUser }, icon('plus'), 'Benutzer anlegen'),
    ),
    h(
      'div',
      { class: 'card' },
      h(
        'div',
        { class: 'table-wrap' },
        h('table', { class: 'table' }, h('thead', null, h('tr', null, h('th', null, 'Name'), h('th', null, 'Rolle'), h('th', null, 'Status'), h('th', null, 'Letzte Anmeldung'), h('th', null, ''))), tableBody),
      ),
    ),
  );
  await render();
}

// ------------------------------------------------------------------ Einstellungen

async function renderSettings(body) {
  let s;
  try {
    s = await get('/api/admin/settings');
  } catch (err) {
    body.append(h('p', { class: 'form-error' }, err.message));
    return;
  }
  const orgName = h('input', { class: 'input', value: s.org_name });
  const dayStart = h('input', { class: 'input', type: 'number', min: 0, max: 23, value: s.day_start_hour });
  const dayEnd = h('input', { class: 'input', type: 'number', min: 1, max: 24, value: s.day_end_hour });
  const slot = h('select', { class: 'input' }, [5, 10, 15, 30, 60].map((m) => h('option', { value: String(m), selected: m === s.slot_minutes }, `${m} Minuten`)));
  const maxHours = h('input', { class: 'input', type: 'number', min: 0.25, max: 168, step: 0.25, value: s.max_booking_minutes / 60 });
  const maxDays = h('input', { class: 'input', type: 'number', min: 1, max: 1095, value: s.max_days_ahead });
  const allowReg = h('input', { type: 'checkbox', checked: s.allow_registration });
  const domains = h('input', { class: 'input', value: s.allowed_email_domains, placeholder: 'z. B. firma.de, firma.com' });
  const equipment = h('textarea', { class: 'input', rows: 3 }, s.equipment_options.join(', '));
  const reminder = h(
    'select',
    { class: 'input' },
    [0, 5, 10, 15, 30, 60, 120, 1440].map((m) => h('option', { value: String(m), selected: m === s.default_reminder_minutes }, m ? (m >= 60 ? `${m / 60} Std. vorher` : `${m} Min. vorher`) : 'keine')),
  );
  const tzIn = h('input', { class: 'input', value: s.timezone || 'Europe/Berlin', placeholder: 'Europe/Berlin' });
  const err = h('div', { class: 'form-error' });
  const saveBtn = h('button', { class: 'btn btn-primary', type: 'submit' }, icon('check'), 'Einstellungen speichern');

  body.append(
    h(
      'form',
      {
        class: 'stack',
        onSubmit: async (e) => {
          e.preventDefault();
          err.textContent = '';
          setBusy(saveBtn, true);
          try {
            await put('/api/admin/settings', {
              org_name: orgName.value,
              day_start_hour: Number(dayStart.value),
              day_end_hour: Number(dayEnd.value),
              slot_minutes: Number(slot.value),
              max_booking_minutes: Math.round(Number(maxHours.value) * 60),
              max_days_ahead: Number(maxDays.value),
              allow_registration: allowReg.checked,
              allowed_email_domains: domains.value,
              equipment_options: equipment.value,
              default_reminder_minutes: Number(reminder.value),
              ...(state.hosted ? { timezone: tzIn.value.trim() } : {}),
            });
            state.config = await get('/api/config');
            toast('Einstellungen gespeichert', { type: 'success' });
          } catch (ex) {
            err.textContent = ex.message;
          } finally {
            setBusy(saveBtn, false);
          }
        },
      },
      h(
        'div',
        { class: 'grid-2' },
        h(
          'div',
          { class: 'card' },
          h('div', { class: 'card-head' }, h('h2', null, 'Allgemein')),
          h(
            'div',
            { class: 'card-body form' },
            field('Name der Organisation', orgName),
            h('div', { class: 'fields-2' }, field('Belegungsplan ab (Uhr)', dayStart), field('bis (Uhr)', dayEnd)),
            field('Zeitraster', slot, 'Schrittweite für Uhrzeiten im Buchungsdialog.'),
            field('Ausstattungsmerkmale', equipment, 'Kommagetrennt, z. B. Beamer, Videokonferenz, Whiteboard.'),
            state.hosted ? field('Zeitzone', tzIn, 'IANA-Name, z. B. Europe/Berlin oder Europe/Vienna.') : null,
          ),
        ),
        h(
          'div',
          { class: 'card' },
          h('div', { class: 'card-head' }, h('h2', null, 'Buchungsregeln & Zugang')),
          h(
            'div',
            { class: 'card-body form' },
            h('div', { class: 'fields-2' }, field('Max. Buchungsdauer (Stunden)', maxHours), field('Max. Tage im Voraus', maxDays)),
            h('p', { class: 'hint' }, 'Gilt für Mitarbeitende; die Administration ist davon ausgenommen.'),
            field('Standard-Erinnerung für neue Konten', reminder),
            state.hosted ? null : h('label', { class: 'check' }, allowReg, h('span', null, 'Selbstregistrierung erlauben')),
            state.hosted ? null : field('Nur diese E-Mail-Domains', domains, 'Leer = alle. Empfohlen: eure Firmen-Domain(s).'),
          ),
        ),
      ),
      err,
      h('div', null, saveBtn),
    ),
  );
}

// ------------------------------------------------------------------ System

function bytes(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

async function renderSystem(body) {
  const render = async () => {
    let sys;
    try {
      sys = await get('/api/admin/system');
    } catch (err) {
      body.replaceChildren(h('p', { class: 'form-error' }, err.message));
      return;
    }
    const mail = sys.mail;
    const modeText = {
      smtp: `SMTP über ${mail.server}`,
      log: 'Nur Protokoll (MAIL_LOG_ONLY) – es werden keine echten E-Mails verschickt',
      disabled: 'Nicht eingerichtet – nur In-App-Benachrichtigungen',
      custom: 'Eigener Transport',
    }[mail.mode];
    const testTo = h('input', { class: 'input', type: 'email', value: state.me.email, 'aria-label': 'Empfänger der Test-E-Mail' });

    body.replaceChildren(
      h(
        'div',
        { class: 'grid-3' },
        stat(sys.counts.users, 'aktive Benutzer'),
        stat(sys.counts.rooms, 'Räume & Arbeitsplätze'),
        stat(sys.counts.upcomingBookings, 'anstehende Buchungen'),
      ),
      h(
        'div',
        { class: 'grid-2' },
        h(
          'div',
          { class: 'card' },
          h('div', { class: 'card-head' }, h('h2', null, icon('mail'), 'E-Mail-Versand')),
          h(
            'div',
            { class: 'card-body stack-sm' },
            h(
              'div',
              { class: `notice ${mail.mode === 'smtp' ? 'success' : mail.mode === 'disabled' ? 'warning' : ''}` },
              icon(mail.mode === 'smtp' ? 'check' : 'info'),
              h('div', null, h('strong', null, modeText), mail.mode !== 'disabled' ? h('div', { class: 'small' }, `Absender: ${mail.from}`) : h('div', { class: 'small' }, 'Trage SMTP_HOST, SMTP_USER, SMTP_PASS und SMTP_FROM in die .env-Datei ein und starte neu.')),
            ),
            mail.lastError ? h('div', { class: 'notice danger' }, icon('alert'), h('div', null, h('strong', null, 'Letzter Fehler: '), mail.lastError.message)) : null,
            h(
              'div',
              { class: 'row' },
              h('span', { class: 'badge' }, `${mail.counts.pending} wartend`),
              h('span', { class: 'badge free' }, `${mail.counts.sent} zugestellt`),
              h('span', { class: `badge ${mail.counts.failed ? 'danger' : ''}` }, `${mail.counts.failed} fehlgeschlagen`),
            ),
            mail.enabled
              ? h(
                  'div',
                  { class: 'copy-field' },
                  testTo,
                  h(
                    'button',
                    {
                      class: 'btn',
                      type: 'button',
                      onClick: async () => {
                        try {
                          await post('/api/admin/mail/test', { to: testTo.value });
                          toast('Test-E-Mail eingereiht', { type: 'success', body: 'Der Status erscheint gleich in der Liste unten.' });
                          setTimeout(render, 1500);
                        } catch (err) {
                          toastError(err);
                        }
                      },
                    },
                    'Test senden',
                  ),
                )
              : null,
            mail.mode === 'smtp'
              ? h(
                  'button',
                  {
                    class: 'btn btn-ghost btn-sm',
                    type: 'button',
                    onClick: async (e) => {
                      setBusy(e.currentTarget, true);
                      const res = await post('/api/admin/mail/verify').catch((err) => ({ ok: false, error: err.message }));
                      setBusy(e.currentTarget, false);
                      toast(res.ok ? 'Verbindung zum Mailserver OK' : 'Verbindung fehlgeschlagen', { type: res.ok ? 'success' : 'error', body: res.error });
                    },
                  },
                  'Verbindung prüfen',
                )
              : null,
          ),
        ),
        h(
          'div',
          { class: 'card' },
          h('div', { class: 'card-head' }, h('h2', null, icon('database'), 'Datensicherung')),
          h(
            'div',
            { class: 'card-body stack-sm' },
            h(
              'p',
              { class: 'small' },
              sys.backupIntervalHours > 0 ? `Automatisch alle ${sys.backupIntervalHours} Stunden nach ` : 'Automatische Sicherung ist deaktiviert. Sicherungsordner: ',
              h('span', { class: 'mono' }, sys.backupDir),
            ),
            sys.backups.length
              ? h(
                  'ul',
                  { class: 'agenda' },
                  sys.backups.slice(0, 5).map((b) => h('li', null, h('span', { class: 'mono' }, b.name), h('span', { class: 'muted' }, `${bytes(b.size)} · ${relativeTime(b.createdAt) || fmt.dateTime(b.createdAt)}`))),
                )
              : h('p', { class: 'muted small' }, 'Noch keine Sicherung vorhanden.'),
            h(
              'div',
              null,
              h(
                'button',
                {
                  class: 'btn',
                  type: 'button',
                  onClick: async (e) => {
                    setBusy(e.currentTarget, true);
                    try {
                      const b = await post('/api/admin/backups');
                      toast('Sicherung erstellt', { type: 'success', body: b.name });
                      render();
                    } catch (err) {
                      toastError(err);
                      setBusy(e.currentTarget, false);
                    }
                  },
                },
                icon('download'),
                'Jetzt sichern',
              ),
            ),
            h('p', { class: 'hint' }, `Datenbank: ${bytes(sys.dbSize)} · Version ${sys.version} · läuft seit ${fmt.dateTime(sys.startedAt)} · ${sys.liveConnections} Live-Verbindungen`),
          ),
        ),
      ),
      h(
        'div',
        { class: 'card' },
        h('div', { class: 'card-head' }, h('h2', null, 'E-Mail-Warteschlange'), h('button', { class: 'btn btn-ghost btn-sm', type: 'button', onClick: render }, icon('refresh'), 'Aktualisieren')),
        sys.outbox.length
          ? h(
              'div',
              { class: 'table-wrap' },
              h(
                'table',
                { class: 'table' },
                h('thead', null, h('tr', null, h('th', null, 'Status'), h('th', null, 'An'), h('th', null, 'Betreff'), h('th', null, 'Zeit'), h('th', null, ''))),
                h(
                  'tbody',
                  null,
                  sys.outbox.map((m) =>
                    h(
                      'tr',
                      null,
                      h(
                        'td',
                        null,
                        h('span', { class: `badge ${m.status === 'sent' ? 'free' : m.status === 'failed' ? 'danger' : 'soon'}` }, { sent: 'zugestellt', failed: 'fehlgeschlagen', pending: m.attempts ? `Versuch ${m.attempts + 1}` : 'wartend' }[m.status]),
                      ),
                      h('td', { class: 'small' }, m.to),
                      h('td', { class: 'small' }, m.subject, m.lastError && m.status !== 'sent' ? h('div', { class: 'muted' }, m.lastError) : null),
                      h('td', { class: 'small muted nowrap' }, fmt.dateTime(m.sentAt || m.createdAt)),
                      h(
                        'td',
                        null,
                        m.status !== 'sent'
                          ? h(
                              'button',
                              {
                                class: 'btn btn-ghost btn-sm',
                                type: 'button',
                                onClick: async () => {
                                  try {
                                    await post(`/api/admin/outbox/${m.id}/retry`);
                                    toast('Wird erneut versucht', { type: 'info', timeout: 2500 });
                                    setTimeout(render, 1500);
                                  } catch (err) {
                                    toastError(err);
                                  }
                                },
                              },
                              'Erneut senden',
                            )
                          : null,
                      ),
                    ),
                  ),
                ),
              ),
            )
          : h('div', { class: 'card-body' }, h('p', { class: 'muted' }, mail.enabled ? 'Noch keine E-Mails verschickt.' : 'E-Mail-Versand ist nicht eingerichtet.')),
      ),
    );
  };
  await render();
}

function stat(value, label) {
  return h('div', { class: 'card stat' }, h('div', { class: 'stat-value' }, String(value)), h('div', { class: 'stat-label' }, label));
}

// ------------------------------------------------------------------ Web-Version: Personen & Daten

async function renderPeopleHosted(body) {
  const tbody = h('tbody');
  const render = async () => {
    let people;
    try {
      people = await get('/api/admin/people');
    } catch (err) {
      tbody.replaceChildren(h('tr', null, h('td', { colspan: 3 }, err.message)));
      return;
    }
    tbody.replaceChildren(
      ...people.map((p) =>
        h(
          'tr',
          null,
          h('td', null, h('strong', null, p.name), p.isMe ? h('span', { class: 'badge primary', style: { marginLeft: '6px' } }, 'du') : null, p.email ? h('div', { class: 'muted small' }, p.email) : null),
          h(
            'td',
            null,
            state.config.isOwner && !p.isMe
              ? h(
                  'select',
                  {
                    class: 'input auto',
                    'aria-label': `Rolle von ${p.name}`,
                    onChange: async (e) => {
                      try {
                        await put(`/api/admin/people/${encodeURIComponent(p.id)}`, { admin: e.target.value === 'admin' });
                        toast('Rolle geändert', { type: 'success', timeout: 2500 });
                      } catch (err) {
                        toastError(err);
                      }
                      render();
                    },
                  },
                  h('option', { value: 'user', selected: !p.isAdmin }, 'Mitarbeiter/in'),
                  h('option', { value: 'admin', selected: p.isAdmin }, 'Administration'),
                )
              : h('span', { class: `badge ${p.isAdmin ? 'primary' : ''}` }, p.isAdmin ? 'Administration' : 'Mitarbeiter/in'),
          ),
          h('td', { class: 'small muted' }, p.lastSeen ? relativeTime(p.lastSeen) || fmt.dateTime(p.lastSeen) : '–'),
        ),
      ),
    );
  };
  body.append(
    h(
      'div',
      { class: 'notice' },
      icon('info'),
      h(
        'div',
        null,
        h('p', null, 'Wer den Raumplaner nutzen darf, legst du in claude.ai über „Teilen“ fest. Personen erscheinen hier, sobald sie ihn einmal geöffnet haben.'),
        h(
          'p',
          { class: 'small', style: { marginTop: '6px' } },
          'Zum Buchen braucht man Schreibzugriff. Wer Gebäude und Pläne verwalten soll, braucht in claude.ai Bearbeitungszugriff und hier die Rolle „Administration“ (vergeben kann sie die Person, der der Raumplaner gehört).',
        ),
      ),
    ),
    h(
      'div',
      { class: 'card' },
      h(
        'div',
        { class: 'table-wrap' },
        h('table', { class: 'table' }, h('thead', null, h('tr', null, h('th', null, 'Person'), h('th', null, 'Rolle'), h('th', null, 'Zuletzt aktiv'))), tbody),
      ),
    ),
  );
  await render();
}

async function renderDataHosted(body) {
  let sys;
  try {
    sys = await get('/api/admin/system');
  } catch (err) {
    body.append(h('p', { class: 'form-error' }, err.message));
    return;
  }
  const exportBtn = h(
    'button',
    {
      class: 'btn btn-primary',
      type: 'button',
      onClick: async () => {
        setBusy(exportBtn, true);
        try {
          await post('/api/admin/export');
          toast('Export erstellt', { type: 'success', body: 'Die Datei enthält Gebäude, Räume, Einstellungen und alle Buchungen.' });
        } catch (err) {
          toastError(err);
        } finally {
          setBusy(exportBtn, false);
        }
      },
    },
    icon('download'),
    'Alle Daten exportieren (JSON)',
  );
  body.append(
    h(
      'div',
      { class: 'grid-3' },
      stat(sys.counts.rooms, 'Räume & Arbeitsplätze'),
      stat(sys.counts.upcomingBookings, 'anstehende Buchungen'),
      stat(sys.counts.people, 'Personen'),
    ),
    h(
      'div',
      { class: 'grid-2' },
      h(
        'div',
        { class: 'card' },
        h('div', { class: 'card-head' }, h('h2', null, icon('database'), 'Datensicherung')),
        h(
          'div',
          { class: 'card-body stack-sm' },
          h('p', null, 'Alle Daten liegen in claude.ai bei diesem Raumplaner. Zusätzlich kannst du jederzeit eine vollständige Kopie herunterladen – zum Archivieren oder zum Umzug auf einen eigenen Server.'),
          h('div', null, exportBtn),
        ),
      ),
      h(
        'div',
        { class: 'card' },
        h('div', { class: 'card-head' }, h('h2', null, icon('refresh'), 'Automatisches Aufräumen')),
        h(
          'div',
          { class: 'card-body stack-sm' },
          h('p', null, 'Damit der Raumplaner schnell bleibt, werden Buchungen nach 60 Tagen und Benachrichtigungen nach 30 Tagen automatisch entfernt.'),
          sys.storage ? h('p', { class: 'hint' }, `Grundrisse: ${sys.storage.files} Datei(en), ${bytes(sys.storage.bytes)} von ${bytes(sys.storage.maxBytes)}`) : null,
        ),
      ),
    ),
  );
}

// ------------------------------------------------------------------ Protokoll

const ACTIONS = {
  setup: 'Einrichtung',
  'booking.create': 'Buchung',
  'booking.update': 'Änderung',
  'booking.cancel': 'Storno',
  'booking.end': 'Vorzeitig beendet',
  'block.create': 'Sperrung',
  'watch.create': 'Raum-Wunsch',
  'building.create': 'Gebäude angelegt',
  'building.update': 'Gebäude geändert',
  'building.delete': 'Gebäude gelöscht',
  'floor.create': 'Etage angelegt',
  'floor.update': 'Etage geändert',
  'floor.delete': 'Etage gelöscht',
  'floor.image': 'Grundriss',
  'room.create': 'Raum angelegt',
  'room.update': 'Raum geändert',
  'room.delete': 'Raum gelöscht',
  'user.register': 'Registrierung',
  'user.create': 'Benutzer angelegt',
  'user.role': 'Rolle',
  'user.activate': 'Aktiviert',
  'user.deactivate': 'Deaktiviert',
  'user.password': 'Passwort geändert',
  'user.password-reset': 'Passwort zurückgesetzt',
  'settings.update': 'Einstellungen',
  'mail.test': 'Test-E-Mail',
  'backup.create': 'Sicherung',
  'demo.load': 'Beispieldaten',
};

async function renderAudit(body) {
  let entries;
  try {
    entries = await get('/api/admin/audit?limit=300');
  } catch (err) {
    body.append(h('p', { class: 'form-error' }, err.message));
    return;
  }
  body.append(
    h('p', { class: 'muted' }, 'Wer hat wann was gebucht, geändert oder storniert – nachvollziehbar für Rückfragen.'),
    h(
      'div',
      { class: 'card' },
      entries.length
        ? h(
            'div',
            { class: 'table-wrap' },
            h(
              'table',
              { class: 'table' },
              h('thead', null, h('tr', null, h('th', null, 'Zeit'), h('th', null, 'Wer'), h('th', null, 'Aktion'), h('th', null, 'Details'))),
              h(
                'tbody',
                null,
                entries.map((a) =>
                  h(
                    'tr',
                    null,
                    h('td', { class: 'small muted nowrap' }, fmt.dateTime(a.createdAt)),
                    h('td', { class: 'small' }, a.userName || '–'),
                    h('td', null, h('span', { class: 'badge' }, ACTIONS[a.action] || a.action)),
                    h('td', { class: 'small' }, a.details),
                  ),
                ),
              ),
            ),
          )
        : h('div', { class: 'card-body' }, h('p', { class: 'muted' }, 'Noch keine Einträge.')),
    ),
  );
}

