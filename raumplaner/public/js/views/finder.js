import { bus, get, post, qs } from '../api.js';
import { openBookingDetails, openBookingDialog, roomFacts } from '../booking-dialog.js';
import { renderPlan } from '../floorplan.js';
import {
  addDays,
  bookableRooms,
  currentSlot,
  dateKey,
  dayBounds,
  floorById,
  fmt,
  fromLocal,
  isAdmin,
  KIND_LABEL,
  roomById,
  roomPlace,
  roomsOfFloor,
  slotMinutes,
  sortedFloors,
  state,
  timeKey,
  todayKey,
} from '../state.js';
import { debounce, emptyState, h, icon, toast, toastError } from '../ui.js';

function timeSelect(value, { end = false } = {}) {
  const step = slotMinutes();
  const sel = h('select', { class: 'input' });
  for (let m = end ? step : 0; m <= (end ? 1440 : 1440 - step); m += step) {
    const v = `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
    sel.append(h('option', { value: v }, v));
  }
  if (![...sel.options].some((o) => o.value === value)) sel.append(h('option', { value }, value));
  sel.value = value;
  return sel;
}

function savedFloor() {
  try {
    return Number(localStorage.getItem('rp.floor')) || null;
  } catch {
    return null;
  }
}

function saveFloor(id) {
  try {
    localStorage.setItem('rp.floor', String(id));
  } catch {
    /* privates Fenster */
  }
}

export async function renderFinder(root, { query }) {
  const floors = sortedFloors();
  root.append(
    h(
      'div',
      { class: 'page-head' },
      h('div', null, h('h1', null, 'Raum finden'), h('p', null, 'Zeitraum und Anforderungen wählen – freie Räume sind im Lageplan grün markiert.')),
    ),
  );
  if (!floors.length) {
    root.append(
      h(
        'div',
        { class: 'card' },
        emptyState(
          'layers',
          'Noch kein Lageplan vorhanden',
          isAdmin() ? 'Lege in der Verwaltung ein Gebäude mit Etagen an und zeichne die Räume ein.' : 'Die Administration hat noch keine Räume hinterlegt.',
          isAdmin() ? [h('a', { class: 'btn btn-primary', href: '#/admin/gebaeude' }, 'Zur Verwaltung')] : [],
        ),
      ),
    );
    return;
  }

  const now = Date.now();
  const startDefault = currentSlot(now);
  const st = {
    date: query.get('date') || todayKey(),
    floorId: Number(query.get('floor')) || savedFloor(),
    selectedId: Number(query.get('room')) || null,
    persons: 1,
    kind: 'room',
    equipment: new Set(),
    avail: null,
    day: [],
  };
  if (!floorById(st.floorId)) st.floorId = (floors.find((f) => roomsOfFloor(f.id).some((r) => r.kind !== 'area')) || floors[0]).id;
  if (st.selectedId && roomById(st.selectedId)) {
    st.floorId = roomById(st.selectedId).floorId;
    if (roomById(st.selectedId).kind === 'desk') st.kind = 'desk';
  }

  // ---------------------------------------------------------------- Filter
  const dateIn = h('input', { class: 'input', type: 'date', value: st.date });
  const fromSel = timeSelect(timeKey(startDefault));
  const toEnd = startDefault + 60 * 60000;
  const toSel = timeSelect(dateKey(toEnd) !== dateKey(startDefault) ? '24:00' : timeKey(toEnd), { end: true });
  const personsIn = h('input', { class: 'input', type: 'number', min: 1, max: 500, value: 1, style: { width: '90px' } });
  const kindGroup = h(
    'div',
    { class: 'btn-group', role: 'group', 'aria-label': 'Art' },
    [
      ['room', 'Räume'],
      ['desk', 'Arbeitsplätze'],
      ['all', 'Alle'],
    ].map(([k, label]) =>
      h(
        'button',
        {
          class: `btn btn-sm${st.kind === k ? ' active' : ''}`,
          type: 'button',
          dataset: { kind: k },
          'aria-pressed': st.kind === k ? 'true' : 'false',
          onClick: () => {
            st.kind = k;
            for (const b of kindGroup.children) {
              b.classList.toggle('active', b.dataset.kind === k);
              b.setAttribute('aria-pressed', b.dataset.kind === k ? 'true' : 'false');
            }
            render();
          },
        },
        label,
      ),
    ),
  );
  const equipChips = h(
    'div',
    { class: 'chips' },
    (state.config.equipmentOptions || []).map((eq) =>
      h(
        'button',
        {
          class: 'chip',
          type: 'button',
          'aria-pressed': 'false',
          onClick: (e) => {
            if (st.equipment.has(eq)) st.equipment.delete(eq);
            else st.equipment.add(eq);
            e.currentTarget.setAttribute('aria-pressed', st.equipment.has(eq) ? 'true' : 'false');
            render();
          },
        },
        eq,
      ),
    ),
  );
  const nowBtn = h(
    'button',
    {
      class: 'btn btn-sm',
      type: 'button',
      title: 'Auf die aktuelle Uhrzeit setzen',
      onClick: () => {
        const s = currentSlot(Date.now());
        dateIn.value = todayKey();
        fromSel.value = timeKey(s);
        const e = s + 60 * 60000;
        toSel.value = dateKey(e) !== dateKey(s) ? '24:00' : timeKey(e);
        load();
      },
    },
    icon('clock'),
    'Jetzt',
  );

  const filterCard = h(
    'div',
    { class: 'card', style: { marginBottom: '16px' } },
    h(
      'div',
      { class: 'toolbar' },
      h('div', { class: 'field' }, h('label', null, 'Datum'), dateIn),
      h('div', { class: 'field' }, h('label', null, 'Von'), fromSel),
      h('div', { class: 'field' }, h('label', null, 'Bis'), toSel),
      h('div', { class: 'field', style: { minWidth: '0' } }, h('span', { class: 'label' }, ' '), nowBtn),
      h('div', { class: 'field', style: { minWidth: '90px' } }, h('label', null, 'Personen'), personsIn),
      h('div', { class: 'field' }, h('span', { class: 'label' }, 'Art'), kindGroup),
    ),
    state.config.equipmentOptions?.length
      ? h('div', { style: { padding: '0 16px 14px' } }, h('div', { class: 'label small muted', style: { marginBottom: '6px', fontWeight: 600 } }, 'Ausstattung'), equipChips)
      : null,
  );

  const tabs = h('div', { class: 'floor-tabs' });
  const planHolder = h('div', { class: 'plan-wrap' });
  const unplaced = h('div', { class: 'unplaced', hidden: true });
  const legend = h(
    'div',
    { class: 'legend' },
    h('span', null, h('span', { class: 'swatch free' }), 'frei'),
    h('span', null, h('span', { class: 'swatch busy' }), 'belegt'),
    h('span', null, h('span', { class: 'swatch blocked' }), 'gesperrt / nicht buchbar'),
    h('span', null, h('span', { class: 'swatch area' }), 'Flur, Küche & Co.'),
    h('span', { class: 'muted' }, 'Blass = passt nicht zu den Filtern'),
  );
  const planCard = h('div', { class: 'card' }, h('div', { class: 'card-head' }, tabs), planHolder, unplaced, legend);
  const roomPanel = h('div', { class: 'card room-card', hidden: true });
  const listCard = h('div', { class: 'card' });

  root.append(filterCard, h('div', { class: 'split' }, planCard, h('div', { class: 'stack' }, roomPanel, listCard)));

  // ---------------------------------------------------------------- Logik
  function range() {
    const d = dateIn.value || todayKey();
    const start = fromLocal(d, fromSel.value);
    const end = toSel.value === '24:00' ? fromLocal(addDays(d, 1), '00:00') : fromLocal(d, toSel.value);
    return { start, end, ok: end > start };
  }

  function matches(room) {
    if (st.kind !== 'all' && room.kind !== st.kind) return false;
    if (st.persons > 1 && room.capacity && room.capacity < st.persons) return false;
    for (const eq of st.equipment) if (!(room.equipment || []).includes(eq)) return false;
    return true;
  }

  function baseStatus(room) {
    if (!room.bookable) return 'disabled';
    const busy = st.avail?.busy[room.id];
    if (busy?.length) return busy.some((b) => b.type === 'block') ? 'blocked' : 'busy';
    return 'free';
  }

  function statusClass(room) {
    return `${baseStatus(room)}${matches(room) ? '' : ' nomatch'}`;
  }

  function statusText(room) {
    const b = baseStatus(room);
    if (b === 'disabled') return 'nicht buchbar';
    if (b === 'blocked') return 'gesperrt';
    if (b === 'busy') {
      const until = Math.max(...st.avail.busy[room.id].map((x) => x.end));
      return `belegt bis ${fmt.time(until)}`;
    }
    return 'frei';
  }

  function lines(room, cls) {
    if (cls === 'area') return [{ text: room.name }];
    const cap = room.kind === 'desk' ? '' : room.capacity ? `${room.capacity} P. · ` : '';
    return [{ text: room.name }, { text: `${cap}${statusText(room)}`, sub: true }];
  }

  function select(room) {
    st.selectedId = room.id;
    if (room.floorId !== st.floorId) {
      st.floorId = room.floorId;
      saveFloor(st.floorId);
    }
    render();
    if (window.matchMedia('(max-width: 1024px)').matches) roomPanel.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  function renderTabs() {
    const byBuilding = new Map();
    for (const f of sortedFloors()) {
      if (!byBuilding.has(f.buildingId)) byBuilding.set(f.buildingId, []);
      byBuilding.get(f.buildingId).push(f);
    }
    const multi = byBuilding.size > 1;
    const parts = [];
    for (const [bId, list] of byBuilding) {
      if (multi) parts.push(h('span', { class: 'group-label' }, state.layout.buildings.find((b) => b.id === bId)?.name));
      for (const f of list) {
        const free = roomsOfFloor(f.id).filter((r) => r.kind !== 'area' && matches(r) && baseStatus(r) === 'free').length;
        parts.push(
          h(
            'button',
            {
              class: `btn btn-sm${f.id === st.floorId ? ' btn-primary' : ''}`,
              type: 'button',
              'aria-pressed': f.id === st.floorId ? 'true' : 'false',
              onClick: () => {
                st.floorId = f.id;
                saveFloor(f.id);
                render();
              },
            },
            f.name,
            st.avail ? h('span', { class: `badge ${free ? 'free' : ''}`, style: { marginLeft: '2px' } }, `${free} frei`) : null,
          ),
        );
      }
    }
    tabs.replaceChildren(...parts);
  }

  function renderPlanArea() {
    const floor = floorById(st.floorId);
    const rooms = roomsOfFloor(floor.id);
    if (!rooms.some((r) => r.shape)) {
      planHolder.replaceChildren(
        emptyState('map', 'Für diese Etage ist noch kein Plan gezeichnet', isAdmin() ? 'Im Grundriss-Editor kannst du die Räume einzeichnen.' : null, isAdmin() ? [h('a', { class: 'btn', href: `#/admin/etage/${floor.id}` }, icon('edit'), 'Grundriss bearbeiten')] : []),
      );
    } else {
      planHolder.replaceChildren(
        renderPlan(floor, rooms, {
          status: statusClass,
          lines,
          selectedId: st.selectedId,
          onSelect: select,
          aria: (room) => `${room.name}, ${KIND_LABEL[room.kind]}, ${statusText(room)}${room.capacity ? `, ${room.capacity} Personen` : ''}`,
        }),
      );
    }
    const missing = rooms.filter((r) => !r.shape && r.kind !== 'area');
    unplaced.hidden = !missing.length;
    unplaced.replaceChildren(
      h('div', { class: 'small muted', style: { marginBottom: '6px' } }, 'Ohne Position im Plan:'),
      h(
        'div',
        { class: 'chips' },
        missing.map((r) => h('button', { class: 'chip', type: 'button', 'aria-pressed': r.id === st.selectedId ? 'true' : 'false', onClick: () => select(r) }, `${r.name} · ${statusText(r)}`)),
      ),
    );
  }

  function renderRoomPanel() {
    const room = st.selectedId && roomById(st.selectedId);
    if (!room) {
      roomPanel.hidden = true;
      return;
    }
    roomPanel.hidden = false;
    const r = range();
    const b = baseStatus(room);
    const agenda = st.day.filter((x) => x.room.id === room.id).sort((a, c) => a.start - c.start);
    const nowTs = Date.now();
    const busyNow = b === 'busy';
    roomPanel.replaceChildren(
      h(
        'div',
        { class: 'card-head' },
        h('div', { class: 'room-title' }, h('h2', null, room.name), h('span', { class: `badge ${b === 'free' ? 'free' : b === 'busy' ? 'busy' : ''}` }, statusText(room))),
        h('button', { class: 'btn btn-ghost btn-icon btn-sm', type: 'button', 'aria-label': 'Auswahl aufheben', onClick: () => ((st.selectedId = null), render()) }, icon('x')),
      ),
      h(
        'div',
        { class: 'card-body stack-sm' },
        h('div', { class: 'muted small' }, roomPlace(room)),
        h('div', null, roomFacts(room)),
        room.description ? h('p', { class: 'small' }, room.description) : null,
        h('div', { class: 'small', style: { fontWeight: 650, marginTop: '6px' } }, `Belegung am ${fmt.date(fromLocal(dateIn.value, '12:00'))}`),
        agenda.length
          ? h(
              'ul',
              { class: 'agenda' },
              agenda.map((x) =>
                h(
                  'li',
                  { class: x.end <= nowTs ? 'past' : '', style: { cursor: 'pointer' }, onClick: () => openBookingDetails(x) },
                  h('span', { class: 'nowrap' }, `${fmt.time(x.start)}–${fmt.time(x.end)}`),
                  h('span', null, x.type === 'block' ? `Gesperrt: ${x.title}` : `${x.title} · ${x.user.name}`),
                ),
              ),
            )
          : h('div', { class: 'muted small' }, 'Keine Buchungen an diesem Tag.'),
        h(
          'div',
          { class: 'row', style: { marginTop: '8px' } },
          room.bookable
            ? h('button', { class: 'btn btn-primary', type: 'button', onClick: () => openBookingDialog({ roomId: room.id, start: r.start, end: r.end }) }, icon('plus'), 'Buchen')
            : h('span', { class: 'muted small' }, 'Dieser Raum ist derzeit nicht buchbar.'),
          busyNow
            ? h(
                'button',
                {
                  class: 'btn',
                  type: 'button',
                  title: 'Du bekommst eine Nachricht, sobald der gewählte Zeitraum frei wird',
                  onClick: async () => {
                    try {
                      const res = await post('/api/watches', { roomId: room.id, start: r.start, end: r.end });
                      toast(res.free ? 'Der Raum ist inzwischen frei!' : 'Vorgemerkt – wir melden uns, sobald der Raum frei wird.', { type: 'success' });
                      if (res.free) load();
                    } catch (err) {
                      toastError(err);
                    }
                  },
                },
                icon('bell'),
                'Benachrichtigen, wenn frei',
              )
            : null,
          h('a', { class: 'btn btn-ghost', href: `#/belegung?${qs({ date: dateIn.value, floor: room.floorId })}` }, icon('calendar'), 'Tagesplan'),
        ),
      ),
    );
  }

  function renderList() {
    const candidates = bookableRooms().filter((room) => matches(room));
    const free = candidates.filter((room) => baseStatus(room) === 'free');
    const r = range();
    listCard.replaceChildren(
      h('div', { class: 'card-head' }, h('h2', null, 'Passend & frei'), h('span', { class: `badge ${free.length ? 'free' : ''}` }, String(free.length))),
      h('p', { class: 'muted small', style: { padding: '4px 18px 0' } }, r.ok ? fmt.range(r.start, r.end) : 'Bitte einen gültigen Zeitraum wählen.'),
      free.length
        ? h(
            'ul',
            { class: 'list card-body flush' },
            free.map((room) =>
              h(
                'li',
                { class: `list-item clickable${room.id === st.selectedId ? ' selected' : ''}`, onClick: () => select(room) },
                h('div', { class: 'list-main' }, h('div', { class: 'list-title' }, room.name), h('div', { class: 'list-meta' }, h('span', null, roomPlace(room)), h('span', null, roomFacts(room)))),
                h(
                  'button',
                  {
                    class: 'btn btn-sm',
                    type: 'button',
                    onClick: (e) => {
                      e.stopPropagation();
                      openBookingDialog({ roomId: room.id, start: r.start, end: r.end });
                    },
                  },
                  'Buchen',
                ),
              ),
            ),
          )
        : h(
            'div',
            { class: 'card-body' },
            emptyState('search', 'Nichts Passendes frei', candidates.length ? 'Probiere einen anderen Zeitraum oder lockere die Filter. Bei belegten Räumen kannst du dich benachrichtigen lassen, sobald sie frei werden.' : 'Kein Raum erfüllt alle Filter.'),
          ),
    );
  }

  function render() {
    renderTabs();
    renderPlanArea();
    renderRoomPanel();
    renderList();
  }

  let seq = 0;
  async function load() {
    const r = range();
    if (!r.ok) {
      st.avail = { busy: {} };
      render();
      return;
    }
    const my = ++seq;
    try {
      const day = dayBounds(dateIn.value || todayKey());
      const [avail, dayList] = await Promise.all([
        get(`/api/availability?${qs({ start: r.start, end: r.end })}`),
        get(`/api/bookings?${qs({ from: day.start, to: day.end })}`),
      ]);
      if (my !== seq) return;
      st.avail = avail;
      st.day = dayList;
      render();
    } catch (err) {
      if (my === seq) toastError(err);
    }
  }

  fromSel.addEventListener('change', () => {
    const d = dateIn.value || todayKey();
    const start = fromLocal(d, fromSel.value);
    const r = range();
    if (!r.ok) {
      const e = start + 60 * 60000;
      toSel.value = dateKey(e) !== d ? '24:00' : timeKey(e);
    }
    load();
  });
  toSel.addEventListener('change', load);
  dateIn.addEventListener('change', load);
  personsIn.addEventListener('input', () => {
    st.persons = Math.max(1, Number(personsIn.value) || 1);
    render();
  });

  render();
  await load();

  const reload = debounce(load, 250);
  const offs = [
    bus.on('bookings-changed', reload),
    bus.on('layout-changed', () => {
      if (!floorById(st.floorId)) st.floorId = sortedFloors()[0]?.id;
      if (st.floorId) render();
    }),
  ];
  return () => offs.forEach((off) => off());
}
