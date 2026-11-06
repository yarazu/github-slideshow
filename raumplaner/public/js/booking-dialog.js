import { expandRecurrence, RECURRENCE_LABELS } from '../shared/time.js';
import { bus, get, post, put, qs } from './api.js';
import {
  addDays,
  bookableRooms,
  dateKey,
  floorById,
  fmt,
  fromLocal,
  isAdmin,
  KIND_LABEL,
  loadDirectory,
  nextSlot,
  roomById,
  roomPlace,
  slotMinutes,
  sortedFloors,
  state,
  timeKey,
  tz,
} from './state.js';
import { debounce, h, icon, openDialog, setBusy, toast, toastError } from './ui.js';

const EMAIL_RE = /^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]{2,}$/;

function timeOptions(selected, { end = false } = {}) {
  const step = slotMinutes();
  const values = [];
  for (let m = end ? step : 0; m <= (end ? 1440 : 1440 - step); m += step) {
    values.push(`${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`);
  }
  if (selected && !values.includes(selected)) values.push(selected);
  values.sort();
  return values.map((t) => h('option', { value: t }, t));
}

function roomOptions(rooms) {
  const groups = [];
  for (const floor of sortedFloors()) {
    const list = rooms.filter((r) => r.floorId === floor.id);
    if (!list.length) continue;
    groups.push(
      h(
        'optgroup',
        { label: roomPlace({ floorId: floor.id }) },
        list.map((r) =>
          h(
            'option',
            { value: String(r.id) },
            `${r.name}${r.capacity ? ` (${r.capacity} P.)` : ''}${r.kind === 'desk' ? ' – Arbeitsplatz' : ''}${r.bookable ? '' : ' – nicht buchbar'}`,
          ),
        ),
      ),
    );
  }
  return groups;
}

const endKeyOf = (start, end) => (dateKey(end) !== dateKey(start) && timeKey(end) === '00:00' ? '24:00' : timeKey(end));

/**
 * Dialog zum Buchen bzw. Bearbeiten.
 * @param {{roomId?:number,start?:number,end?:number,booking?:object,onDone?:Function}} opts
 */
export function openBookingDialog({ roomId, start, end, booking, onDone } = {}) {
  const editing = Boolean(booking);
  const admin = isAdmin();
  const rooms = bookableRooms({ includeDisabled: admin });
  if (!rooms.length) {
    toast('Es sind noch keine buchbaren Räume angelegt.', { type: 'error', body: admin ? 'Lege unter „Verwaltung“ Gebäude und Räume an.' : 'Bitte wende dich an die Administration.' });
    return null;
  }
  const s0 = booking?.start ?? start ?? nextSlot();
  const e0 = booking?.end ?? end ?? s0 + 60 * 60000;
  const multiDay = dateKey(s0) !== dateKey(e0 - 1);
  const initialRoom = roomById(booking?.room.id ?? roomId) || rooms[0];

  // ---------------------------------------------------------------- Felder
  const roomSel = h('select', { class: 'input', id: 'bk-room' }, roomOptions(rooms));
  roomSel.value = String(initialRoom.id);
  const typeSel =
    admin && !editing
      ? h('select', { class: 'input', id: 'bk-type' }, h('option', { value: 'booking' }, 'Buchung'), h('option', { value: 'block' }, 'Sperrung (Wartung, Umbau …)'))
      : null;
  const titleIn = h('input', {
    class: 'input',
    id: 'bk-title',
    maxlength: 200,
    autocomplete: 'off',
    placeholder: 'z. B. Teammeeting, Kundentermin …',
    value: booking?.title ?? (initialRoom.kind === 'desk' ? 'Arbeitsplatz' : ''),
  });
  const titleLabel = h('label', { for: 'bk-title' }, 'Titel');
  const dateIn = h('input', { class: 'input', type: 'date', id: 'bk-date', value: dateKey(s0), required: true, disabled: multiDay });
  const fromSel = h('select', { class: 'input', id: 'bk-from', disabled: multiDay }, timeOptions(timeKey(s0)));
  fromSel.value = timeKey(s0);
  const toSel = h('select', { class: 'input', id: 'bk-to', disabled: multiDay }, timeOptions(endKeyOf(s0, e0), { end: true }));
  toSel.value = endKeyOf(s0, e0);

  const recSel = editing ? null : h('select', { class: 'input', id: 'bk-rec' }, Object.entries(RECURRENCE_LABELS).map(([k, v]) => h('option', { value: k }, v)));
  const untilIn = editing ? null : h('input', { class: 'input', type: 'date', id: 'bk-until', value: addDays(dateKey(s0), 28) });
  const recInfo = h('div', { class: 'hint' });
  const recUntilField = editing ? null : h('div', { class: 'field', hidden: true }, h('label', { for: 'bk-until' }, 'Wiederholen bis'), untilIn);

  const attendees = new Map((booking?.attendees || []).map((a) => [a.email.toLowerCase(), a.name || null]));
  const datalistId = `dl-${Math.random().toString(36).slice(2, 8)}`;
  const datalist = h('datalist', { id: datalistId });
  const attIn = h('input', { type: 'text', list: datalistId, autocomplete: 'off', placeholder: 'E-Mail oder Name, Enter zum Hinzufügen', 'aria-label': 'Teilnehmende hinzufügen' });
  const tokenBox = h('div', { class: 'token-input' });
  const attHint = h('div', { class: 'hint' }, 'Alle Teilnehmenden erhalten eine Einladung mit Kalendereintrag und werden über Änderungen informiert.');
  const descIn = h('textarea', { class: 'input', id: 'bk-desc', rows: 2, maxlength: 4000, placeholder: 'Optional: Agenda, Hinweise …' }, booking?.description ?? '');
  const privIn = h('input', { type: 'checkbox', checked: Boolean(booking?.isPrivate) });
  const blockNotice = h(
    'div',
    { class: 'notice warning', hidden: true },
    icon('alert'),
    h('div', null, 'Bestehende Buchungen in diesem Zeitraum werden storniert. Die Betroffenen werden automatisch benachrichtigt.'),
  );
  const availBox = h('div', { class: 'avail', role: 'status', 'aria-live': 'polite' }, 'Prüfe Verfügbarkeit …');
  const capacityHint = h('div', { class: 'hint', hidden: true });
  const errBox = h('div', { class: 'form-error', role: 'alert' });

  let directory = [];
  loadDirectory(true)
    .then((users) => {
      directory = users;
      datalist.replaceChildren(...users.filter((u) => u.email !== state.me.email).map((u) => h('option', { value: u.email }, u.name)));
      renderTokens();
    })
    .catch(() => {});

  function nameFor(email) {
    return attendees.get(email) || directory.find((u) => u.email.toLowerCase() === email)?.name || null;
  }

  function renderTokens() {
    tokenBox.replaceChildren(
      ...[...attendees.keys()].map((email) => {
        const name = nameFor(email);
        return h(
          'span',
          { class: 'chip static', title: email },
          name ? `${name}` : email,
          h(
            'button',
            {
              class: 'chip-x',
              type: 'button',
              'aria-label': `${email} entfernen`,
              onClick: () => {
                attendees.delete(email);
                renderTokens();
                updateCapacityHint();
              },
            },
            icon('x'),
          ),
        );
      }),
      attIn,
    );
  }

  function addAttendees(raw) {
    let ok = true;
    for (const part of String(raw).split(/[,;\n]+/)) {
      let v = part.trim();
      if (!v) continue;
      const angle = /<([^>]+)>/.exec(v);
      if (angle) v = angle[1];
      v = v.trim().toLowerCase();
      if (!EMAIL_RE.test(v)) {
        const match = directory.find((u) => u.name.toLowerCase() === part.trim().toLowerCase());
        if (match) v = match.email.toLowerCase();
        else {
          errBox.textContent = `„${part.trim()}“ ist keine gültige E-Mail-Adresse.`;
          ok = false;
          continue;
        }
      }
      if (v !== state.me.email.toLowerCase()) attendees.set(v, attendees.get(v) || null);
    }
    renderTokens();
    updateCapacityHint();
    return ok;
  }

  attIn.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ',' || e.key === ';') {
      e.preventDefault();
      if (attIn.value.trim() && addAttendees(attIn.value)) attIn.value = '';
    } else if (e.key === 'Backspace' && !attIn.value && attendees.size) {
      attendees.delete([...attendees.keys()].pop());
      renderTokens();
    }
  });
  attIn.addEventListener('input', (e) => {
    // Auswahl aus der Vorschlagsliste übernehmen
    if (!e.inputType || e.inputType === 'insertReplacementText') {
      if (EMAIL_RE.test(attIn.value.trim()) && directory.some((u) => u.email === attIn.value.trim())) {
        addAttendees(attIn.value);
        attIn.value = '';
      }
    }
  });
  attIn.addEventListener('blur', () => {
    if (attIn.value.trim() && addAttendees(attIn.value)) attIn.value = '';
  });
  renderTokens();

  // ---------------------------------------------------------------- Logik
  function currentRange() {
    if (multiDay) return { ok: true, start: s0, end: e0 };
    const d = dateIn.value;
    if (!d) return { ok: false, error: 'Bitte ein Datum wählen.' };
    const start = fromLocal(d, fromSel.value);
    const end = toSel.value === '24:00' ? fromLocal(addDays(d, 1), '00:00') : fromLocal(d, toSel.value);
    if (!Number.isFinite(start) || !Number.isFinite(end)) return { ok: false, error: 'Bitte ein gültiges Datum wählen.' };
    if (!(end > start)) return { ok: false, error: 'Das Ende muss nach dem Beginn liegen.' };
    return { ok: true, start, end };
  }

  let lastDuration = e0 - s0;
  fromSel.addEventListener('change', () => {
    const d = dateIn.value;
    const start = fromLocal(d, fromSel.value);
    const dayEnd = fromLocal(addDays(d, 1), '00:00');
    const end = Math.min(start + lastDuration, dayEnd);
    const key = end === dayEnd ? '24:00' : timeKey(end);
    if (![...toSel.options].some((o) => o.value === key)) toSel.append(h('option', { value: key }, key));
    toSel.value = key;
    refresh();
  });
  toSel.addEventListener('change', () => {
    const r = currentRange();
    if (r.ok) lastDuration = r.end - r.start;
    refresh();
  });
  dateIn.addEventListener('change', refresh);
  roomSel.addEventListener('change', () => {
    const room = roomById(roomSel.value);
    if (room?.kind === 'desk' && !titleIn.value.trim()) titleIn.value = 'Arbeitsplatz';
    refresh();
  });

  function updateType() {
    const block = typeSel?.value === 'block';
    titleLabel.textContent = block ? 'Grund der Sperrung' : 'Titel';
    titleIn.placeholder = block ? 'z. B. Malerarbeiten, Technik-Wartung …' : 'z. B. Teammeeting, Kundentermin …';
    blockNotice.hidden = !block;
    attendeeField.hidden = block;
    privField.hidden = block;
    saveBtn.replaceChildren(icon(block ? 'lock' : 'check'), block ? 'Sperren' : editing ? 'Speichern' : 'Buchen');
    checkAvailability();
  }
  typeSel?.addEventListener('change', updateType);

  function updateRecurrence() {
    if (!recSel) return;
    const on = recSel.value !== 'none';
    recUntilField.hidden = !on;
    recInfo.textContent = '';
    if (!on) return;
    const r = currentRange();
    if (!r.ok || !untilIn.value) return;
    try {
      const occ = expandRecurrence(r.start, r.end, { freq: recSel.value, until: untilIn.value }, tz());
      recInfo.textContent = `${occ.length} Termin${occ.length === 1 ? '' : 'e'} – letzter am ${fmt.date(occ[occ.length - 1].start)}${occ.length >= 100 ? ' (Maximum erreicht)' : ''}`;
    } catch (err) {
      recInfo.textContent = err.message;
    }
  }
  recSel?.addEventListener('change', updateRecurrence);
  untilIn?.addEventListener('change', updateRecurrence);

  function updateCapacityHint() {
    const room = roomById(roomSel.value);
    const people = attendees.size + 1;
    if (room?.capacity && people > room.capacity) {
      capacityHint.hidden = false;
      capacityHint.textContent = `Hinweis: ${room.name} ist für ${room.capacity} Person${room.capacity === 1 ? '' : 'en'} ausgelegt – eingeplant sind ${people}.`;
    } else capacityHint.hidden = true;
  }

  let checkSeq = 0;
  const checkAvailability = debounce(async () => {
    const r = currentRange();
    if (!r.ok) {
      availBox.className = 'avail';
      availBox.replaceChildren(icon('info'), h('div', null, r.error));
      return;
    }
    const seq = ++checkSeq;
    try {
      const res = await get(`/api/availability?${qs({ start: r.start, end: r.end, exclude: booking?.id })}`);
      if (seq !== checkSeq) return;
      renderAvailability(res, r);
    } catch (err) {
      if (seq !== checkSeq) return;
      availBox.className = 'avail';
      availBox.replaceChildren(icon('alert'), h('div', null, `Verfügbarkeit konnte nicht geprüft werden: ${err.message}`));
    }
  }, 180);

  function alternatives(res, room) {
    const people = Math.max(1, attendees.size + 1);
    return bookableRooms()
      .filter((r) => r.id !== room.id && r.kind === room.kind && !res.busy[r.id] && (!r.capacity || r.capacity >= Math.min(people, room.capacity || people)))
      // gleiche Etage zuerst, dann möglichst ähnliche Größe wie der Wunschraum
      .sort(
        (a, b) =>
          (a.floorId === room.floorId ? 0 : 1) - (b.floorId === room.floorId ? 0 : 1) ||
          Math.abs((a.capacity || 0) - (room.capacity || 0)) - Math.abs((b.capacity || 0) - (room.capacity || 0)),
      )
      .slice(0, 4);
  }

  function renderAvailability(res, r) {
    const room = roomById(roomSel.value);
    const conflicts = res.busy[room.id] || [];
    if (!conflicts.length) {
      availBox.className = 'avail free';
      availBox.replaceChildren(icon('check'), h('div', null, h('strong', null, `${room.name} ist frei`), ` – ${fmt.range(r.start, r.end)}`));
      return;
    }
    if (typeSel?.value === 'block') {
      const blocks = conflicts.filter((c) => c.type === 'block');
      availBox.className = 'avail busy';
      availBox.replaceChildren(
        icon('alert'),
        h(
          'div',
          null,
          h('strong', null, blocks.length ? 'Für diesen Zeitraum besteht bereits eine Sperrung' : `${conflicts.length} Buchung${conflicts.length === 1 ? '' : 'en'} würde${conflicts.length === 1 ? '' : 'n'} storniert`),
          h(
            'ul',
            { style: { margin: '4px 0 0', paddingLeft: '18px' } },
            conflicts.map((c) => h('li', null, `${fmt.time(c.start)}–${fmt.time(c.end)}: ${c.type === 'block' ? `Gesperrt (${c.title})` : `${c.title} – ${c.user.name}`}`)),
          ),
          blocks.length ? null : h('div', { class: 'small', style: { marginTop: '4px' } }, 'Die Betroffenen werden automatisch per App und E-Mail informiert.'),
        ),
      );
      return;
    }
    const alts = alternatives(res, room);
    availBox.className = 'avail busy';
    availBox.replaceChildren(
      icon('x'),
      h(
        'div',
        { style: { minWidth: '0' } },
        h('strong', null, `${room.name} ist in diesem Zeitraum belegt`),
        h(
          'ul',
          { style: { margin: '4px 0 0', paddingLeft: '18px' } },
          conflicts.map((c) => h('li', null, `${fmt.time(c.start)}–${fmt.time(c.end)}: ${c.type === 'block' ? `Gesperrt (${c.title})` : `${c.title} – ${c.user.name}`}`)),
        ),
        h(
          'div',
          { class: 'avail-actions' },
          !editing && typeSel?.value !== 'block'
            ? h('button', { class: 'btn btn-sm', type: 'button', onClick: () => watch() }, icon('bell'), 'Benachrichtigen, wenn frei')
            : null,
          alts.map((alt) =>
            h(
              'button',
              {
                class: 'btn btn-sm',
                type: 'button',
                title: `${alt.name} (${roomPlace(alt)}) ist frei`,
                onClick: () => {
                  roomSel.value = String(alt.id);
                  refresh();
                },
              },
              icon('check'),
              `${alt.name}${alt.floorId !== room.floorId ? ` · ${floorById(alt.floorId)?.name}` : ''}${alt.capacity ? ` (${alt.capacity} P.)` : ''}`,
            ),
          ),
        ),
        alts.length ? h('div', { class: 'small', style: { marginTop: '4px', color: 'var(--text-2)' } }, 'Freie Alternativen zur gleichen Zeit (Klick zum Wechseln).') : null,
      ),
    );
  }

  async function watch() {
    const r = currentRange();
    if (!r.ok) return;
    try {
      const res = await post('/api/watches', { roomId: Number(roomSel.value), start: r.start, end: r.end });
      if (res.free) {
        toast('Der Raum ist gerade frei geworden – du kannst direkt buchen.', { type: 'success' });
        refresh();
      } else {
        toast('Vorgemerkt!', {
          type: 'success',
          body: `Sobald ${roomById(roomSel.value).name} frei wird, bekommst du eine Benachrichtigung${state.config.mailEnabled ? ' – auch per E-Mail' : ''}.`,
        });
        d.close();
      }
    } catch (err) {
      toastError(err);
    }
  }

  function refresh() {
    errBox.textContent = '';
    updateRecurrence();
    updateCapacityHint();
    checkAvailability();
  }

  // ---------------------------------------------------------------- Absenden
  let skipConflicts = false;
  async function submit(e) {
    e?.preventDefault();
    errBox.textContent = '';
    const r = currentRange();
    if (!r.ok) {
      errBox.textContent = r.error;
      return;
    }
    if (attIn.value.trim()) {
      if (!addAttendees(attIn.value)) return;
      attIn.value = '';
    }
    const type = typeSel?.value || booking?.type || 'booking';
    const room = roomById(roomSel.value);
    const title = titleIn.value.trim() || (type === 'block' ? 'Gesperrt' : room.kind === 'desk' ? 'Arbeitsplatz' : '');
    if (!title) {
      errBox.textContent = 'Bitte gib einen Titel an.';
      titleIn.focus();
      return;
    }
    const payload = {
      roomId: room.id,
      title,
      description: descIn.value,
      isPrivate: privIn.checked,
      attendees: type === 'block' ? [] : [...attendees.keys()],
    };
    if (!multiDay || !editing) Object.assign(payload, { start: r.start, end: r.end });
    if (!editing) {
      payload.type = type;
      if (recSel.value !== 'none') payload.recurrence = { freq: recSel.value, until: untilIn.value };
      if (skipConflicts) payload.skipConflicts = true;
    }
    setBusy(saveBtn, true);
    try {
      const res = editing ? await put(`/api/bookings/${booking.id}`, payload) : await post('/api/bookings', payload);
      d.close();
      const count = editing ? 1 : res.bookings.length;
      const mail = state.config.mailEnabled && type === 'booking';
      toast(editing ? 'Änderung gespeichert' : type === 'block' ? 'Raum gesperrt' : count > 1 ? `${count} Termine gebucht` : 'Gebucht!', {
        type: 'success',
        body: [
          `${room.name}, ${fmt.range(r.start, r.end)}`,
          !editing && res.skipped ? `${res.skipped} belegte Termine wurden übersprungen.` : '',
          mail ? (editing ? 'Alle Beteiligten werden informiert.' : 'Die Bestätigung kommt per E-Mail.') : '',
        ]
          .filter(Boolean)
          .join(' '),
      });
      if (!editing && res.cancelled) {
        toast(`${res.cancelled} Buchung(en) wegen der Sperrung storniert`, { body: 'Die Betroffenen wurden benachrichtigt.', type: 'info' });
      }
      bus.emit('bookings-changed', { local: true });
      onDone?.(res);
    } catch (err) {
      if (err.status === 409 && err.body?.conflicts?.length) showConflicts(err.body);
      else errBox.textContent = err.message;
    } finally {
      setBusy(saveBtn, false);
    }
  }

  function showConflicts(body) {
    const total = body.occurrences || 1;
    const list = body.conflicts;
    const canSkip = !editing && total > 1 && list.length < total;
    errBox.replaceChildren(
      ...[
      h('div', null, body.message),
      h(
        'ul',
        { style: { margin: '4px 0', paddingLeft: '18px', fontWeight: 'normal' } },
        list.slice(0, 8).map((c) => h('li', null, `${fmt.range(c.start, c.end)} – belegt durch ${c.bookings.map((b) => (b.type === 'block' ? 'Sperrung' : b.user.name)).join(', ')}`)),
        list.length > 8 ? h('li', null, `… und ${list.length - 8} weitere`) : null,
      ),
      canSkip
        ? h(
            'button',
            {
              class: 'btn btn-sm',
              type: 'button',
              onClick: () => {
                skipConflicts = true;
                submit();
              },
            },
            `Ohne die belegten Termine buchen (${total - list.length} von ${total})`,
          )
        : null,
      ].filter(Boolean),
    );
    checkAvailability();
  }

  // ---------------------------------------------------------------- Aufbau
  const attendeeField = h('div', { class: 'field' }, h('span', { class: 'label' }, 'Teilnehmende'), tokenBox, datalist, attHint);
  const privField = h('label', { class: 'check' }, privIn, h('span', null, 'Privat – andere sehen nur „Privater Termin“'));

  const form = h(
    'form',
    { class: 'form', onSubmit: submit, novalidate: true },
    h('div', { class: 'field' }, h('label', { for: 'bk-room' }, 'Raum'), roomSel),
    h('div', { class: 'field' }, titleLabel, titleIn),
    h(
      'div',
      { class: 'fields-3' },
      h('div', { class: 'field' }, h('label', { for: 'bk-date' }, 'Datum'), dateIn),
      h('div', { class: 'field' }, h('label', { for: 'bk-from' }, 'Von'), fromSel),
      h('div', { class: 'field' }, h('label', { for: 'bk-to' }, 'Bis'), toSel),
    ),
    multiDay ? h('div', { class: 'hint' }, `Mehrtägiger Zeitraum: ${fmt.range(s0, e0)} – Zeiten können hier nicht geändert werden.`) : null,
    availBox,
    recSel
      ? h(
          'div',
          { class: 'fields-2' },
          h('div', { class: 'field' }, h('label', { for: 'bk-rec' }, 'Wiederholung'), recSel),
          recUntilField,
        )
      : null,
    recSel ? recInfo : null,
    attendeeField,
    capacityHint,
    h('div', { class: 'field' }, h('label', { for: 'bk-desc' }, 'Beschreibung'), descIn),
    privField,
    typeSel ? h('div', { class: 'field' }, h('label', { for: 'bk-type' }, 'Art (nur Administration)'), typeSel) : null,
    blockNotice,
    errBox,
    h('button', { type: 'submit', hidden: true, tabindex: -1 }),
  );

  const saveBtn = h('button', { class: 'btn btn-primary', type: 'button', onClick: submit }, icon('check'), editing ? 'Speichern' : 'Buchen');
  const d = openDialog({
    title: editing ? 'Buchung bearbeiten' : 'Raum buchen',
    content: form,
    actions: [h('button', { class: 'btn', type: 'button', onClick: () => d.close() }, 'Abbrechen'), saveBtn],
  });
  if (typeSel) updateType();
  refresh();
  setTimeout(() => (editing ? titleIn : titleIn.value ? fromSel : titleIn).focus(), 30);
  return d;
}

// ------------------------------------------------------------------ Details & Storno

export async function openBookingDetails(idOrBooking, { onChange } = {}) {
  let b;
  try {
    b = await get(`/api/bookings/${typeof idOrBooking === 'object' ? idOrBooking.id : idOrBooking}`);
  } catch (err) {
    toastError(err, 'Die Buchung konnte nicht geladen werden.');
    return;
  }
  const now = Date.now();
  const ongoing = b.start <= now && b.end > now;
  const room = roomById(b.room.id);
  const badges = [
    b.status === 'cancelled' ? h('span', { class: 'badge danger' }, 'Storniert') : null,
    b.status === 'confirmed' && ongoing ? h('span', { class: 'badge free' }, 'Läuft gerade') : null,
    b.status === 'confirmed' && b.end <= now ? h('span', { class: 'badge' }, 'Vergangen') : null,
    b.type === 'block' ? h('span', { class: 'badge' }, icon('lock'), 'Sperrung') : null,
    b.seriesId ? h('span', { class: 'badge primary' }, icon('repeat'), 'Serientermin') : null,
    b.isPrivate ? h('span', { class: 'badge' }, icon('lock'), 'Privat') : null,
  ].filter(Boolean);

  const content = h(
    'div',
    { class: 'stack' },
    badges.length ? h('div', { class: 'row' }, badges) : null,
    h(
      'dl',
      { class: 'detail-grid' },
      h('dt', null, 'Wann'),
      h('dd', null, fmt.range(b.start, b.end)),
      h('dt', null, 'Raum'),
      h('dd', null, h('strong', null, b.room.name), ` · ${b.floor.name} · ${b.building.name}`, room ? h('div', { class: 'muted small' }, roomFacts(room)) : null),
      h('dt', null, b.type === 'block' ? 'Gesperrt von' : 'Gebucht von'),
      h('dd', null, `${b.user.name} `, h('a', { href: `mailto:${b.user.email}` }, b.user.email)),
      b.attendees.length ? [h('dt', null, 'Teilnehmende'), h('dd', null, b.attendees.map((a) => a.name || a.email).join(', '))] : null,
      b.description ? [h('dt', null, 'Beschreibung'), h('dd', { style: { whiteSpace: 'pre-wrap' } }, b.description)] : null,
      b.cancelReason ? [h('dt', null, 'Grund'), h('dd', null, b.cancelReason)] : null,
    ),
  );

  const actions = [];
  if (!b.masked && b.status === 'confirmed') {
    actions.push(h('a', { class: 'btn', href: `/api/bookings/${b.id}/ics`, download: `termin-${b.id}.ics` }, icon('download'), 'In Kalender'));
  }
  actions.push(h('span', { class: 'spacer' }));
  if (b.canEdit) {
    if (ongoing) {
      actions.push(
        h(
          'button',
          {
            class: 'btn',
            type: 'button',
            title: 'Termin endet jetzt – der Raum wird sofort für andere frei',
            onClick: async (e) => {
              setBusy(e.currentTarget, true);
              try {
                await post(`/api/bookings/${b.id}/end`);
                toast('Raum freigegeben', { type: 'success', body: 'Danke! Der Raum ist ab jetzt wieder buchbar.' });
                d.close();
                bus.emit('bookings-changed', { local: true });
                onChange?.();
              } catch (err) {
                toastError(err);
              }
            },
          },
          icon('stop'),
          'Jetzt beenden',
        ),
      );
    }
    actions.push(
      h(
        'button',
        {
          class: 'btn btn-danger',
          type: 'button',
          onClick: () => {
            d.close();
            openCancelDialog(b, { onDone: onChange });
          },
        },
        icon('trash'),
        'Stornieren',
      ),
    );
    actions.push(
      h(
        'button',
        {
          class: 'btn btn-primary',
          type: 'button',
          onClick: () => {
            d.close();
            openBookingDialog({ booking: b, onDone: onChange });
          },
        },
        icon('edit'),
        'Bearbeiten',
      ),
    );
  } else {
    actions.push(h('button', { class: 'btn', type: 'button', onClick: () => d.close() }, 'Schließen'));
  }
  const d = openDialog({ title: b.title, content, actions });
}

export function roomFacts(room) {
  return [KIND_LABEL[room.kind], room.capacity ? `${room.capacity} Person${room.capacity === 1 ? '' : 'en'}` : null, ...(room.equipment || [])]
    .filter(Boolean)
    .join(' · ');
}

export function openCancelDialog(b, { onDone } = {}) {
  const series = Boolean(b.seriesId);
  const othersBooking = b.user.id !== state.me.id;
  let scope = 'single';
  const reasonIn = h('textarea', {
    class: 'input',
    rows: 2,
    maxlength: 300,
    placeholder: othersBooking ? 'z. B. Raum wird für eine Vorstandssitzung benötigt' : 'Optional',
  });
  const scopeField = series
    ? h(
        'div',
        { class: 'stack-sm' },
        h('label', { class: 'check' }, h('input', { type: 'radio', name: 'cancel-scope', checked: true, onChange: () => (scope = 'single') }), 'Nur diesen Termin'),
        h('label', { class: 'check' }, h('input', { type: 'radio', name: 'cancel-scope', onChange: () => (scope = 'series') }), 'Diesen und alle folgenden Termine der Serie'),
      )
    : null;
  const err = h('div', { class: 'form-error', role: 'alert' });
  const btn = h(
    'button',
    {
      class: 'btn btn-danger',
      type: 'button',
      onClick: async () => {
        setBusy(btn, true);
        try {
          const res = await post(`/api/bookings/${b.id}/cancel`, { scope, reason: reasonIn.value });
          d.close();
          toast(res.cancelled > 1 ? `${res.cancelled} Termine storniert` : 'Buchung storniert', {
            type: 'success',
            body: b.type === 'block' ? 'Die Sperrung ist aufgehoben.' : 'Der Raum ist wieder frei. Alle Beteiligten wurden benachrichtigt.',
          });
          bus.emit('bookings-changed', { local: true });
          onDone?.();
        } catch (e) {
          err.textContent = e.message;
        } finally {
          setBusy(btn, false);
        }
      },
    },
    'Stornieren',
  );
  const d = openDialog({
    title: b.type === 'block' ? 'Sperrung aufheben?' : 'Buchung stornieren?',
    content: h(
      'div',
      { class: 'form' },
      h('p', null, h('strong', null, b.title), ` – ${b.room.name}, ${fmt.range(b.start, b.end)}`),
      scopeField,
      b.type === 'block' ? null : h('div', { class: 'field' }, h('label', null, othersBooking ? 'Grund (wird den Betroffenen mitgeteilt)' : 'Grund (optional)'), reasonIn),
      err,
    ),
    actions: [h('button', { class: 'btn', type: 'button', onClick: () => d.close() }, 'Zurück'), btn],
  });
}
