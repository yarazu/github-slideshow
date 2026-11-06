import { bus, get, qs } from '../api.js';
import { openBookingDetails, openBookingDialog } from '../booking-dialog.js';
import {
  addDays,
  bookableRooms,
  currentSlot,
  dayBounds,
  floorById,
  fmt,
  fromLocal,
  isAdmin,
  minutesOfDay,
  roomPlace,
  slotMinutes,
  sortedFloors,
  state,
  todayKey,
} from '../state.js';
import { debounce, emptyState, h, icon, toast } from '../ui.js';

const pad = (n) => String(n).padStart(2, '0');

function stored(key, fallback) {
  try {
    return localStorage.getItem(key) ?? fallback;
  } catch {
    return fallback;
  }
}

function store(key, value) {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* egal */
  }
}

export async function renderTimeline(root, { query }) {
  const st = {
    date: query.get('date') || todayKey(),
    floor: query.get('floor') || stored('rp.tl.floor', 'all'),
    kind: stored('rp.tl.kind', 'room'),
    bookings: [],
  };
  if (st.floor !== 'all' && !floorById(st.floor)) st.floor = 'all';

  const dateIn = h('input', { class: 'input auto', type: 'date', value: st.date, 'aria-label': 'Datum' });
  const floorSel = h(
    'select',
    { class: 'input auto', 'aria-label': 'Etage' },
    h('option', { value: 'all' }, 'Alle Etagen'),
    sortedFloors().map((f) => h('option', { value: String(f.id) }, roomPlace({ floorId: f.id }))),
  );
  floorSel.value = String(st.floor);
  const kindSel = h(
    'select',
    { class: 'input auto', 'aria-label': 'Art' },
    h('option', { value: 'room' }, 'Räume'),
    h('option', { value: 'desk' }, 'Arbeitsplätze'),
    h('option', { value: 'all' }, 'Räume & Arbeitsplätze'),
  );
  kindSel.value = st.kind;
  const dayLabel = h('div', { class: 'muted', style: { fontWeight: 600 } });

  const shift = (days) => {
    dateIn.value = addDays(dateIn.value || todayKey(), days);
    st.date = dateIn.value;
    load();
  };

  root.append(
    h(
      'div',
      { class: 'page-head' },
      h('div', null, h('h1', null, 'Belegungsplan'), h('p', null, 'In eine freie Zeile klicken oder ziehen, um zu buchen. Klick auf einen Termin zeigt Details.')),
      h('button', { class: 'btn btn-primary', type: 'button', onClick: () => openBookingDialog() }, icon('plus'), 'Raum buchen'),
    ),
  );
  const tlRoot = h('div', { class: 'tl-scroll' });
  root.append(
    h(
      'div',
      { class: 'card' },
      h(
        'div',
        { class: 'toolbar', style: { alignItems: 'center' } },
        h(
          'div',
          { class: 'row' },
          h('button', { class: 'btn btn-icon', type: 'button', 'aria-label': 'Vorheriger Tag', onClick: () => shift(-1) }, icon('left')),
          h(
            'button',
            {
              class: 'btn',
              type: 'button',
              onClick: () => {
                dateIn.value = todayKey();
                st.date = dateIn.value;
                load();
              },
            },
            'Heute',
          ),
          h('button', { class: 'btn btn-icon', type: 'button', 'aria-label': 'Nächster Tag', onClick: () => shift(1) }, icon('right')),
          dateIn,
        ),
        dayLabel,
        h('div', { class: 'row', style: { marginLeft: 'auto' } }, floorSel, kindSel),
      ),
      tlRoot,
    ),
  );

  dateIn.addEventListener('change', () => {
    if (!dateIn.value) return;
    st.date = dateIn.value;
    load();
  });
  floorSel.addEventListener('change', () => {
    st.floor = floorSel.value;
    store('rp.tl.floor', st.floor);
    render();
  });
  kindSel.addEventListener('change', () => {
    st.kind = kindSel.value;
    store('rp.tl.kind', st.kind);
    render();
  });

  function visibleRooms() {
    return bookableRooms({ includeDisabled: true }).filter(
      (r) => (st.floor === 'all' || r.floorId === Number(st.floor)) && (st.kind === 'all' || r.kind === st.kind),
    );
  }

  function render() {
    const date = st.date;
    dayLabel.textContent = fmt.dateLong(fromLocal(date, '12:00'));
    const rooms = visibleRooms();
    if (!rooms.length) {
      tlRoot.replaceChildren(
        emptyState(
          'calendar',
          'Keine Räume für diese Auswahl',
          bookableRooms().length ? 'Wähle eine andere Etage oder Art.' : isAdmin() ? 'Lege in der Verwaltung Räume an.' : 'Es sind noch keine Räume angelegt.',
        ),
      );
      return;
    }
    const day = dayBounds(date);
    let startHour = state.config.dayStartHour;
    let endHour = state.config.dayEndHour;
    const roomIds = new Set(rooms.map((r) => r.id));
    for (const b of st.bookings) {
      if (!roomIds.has(b.room.id)) continue;
      if (b.start > day.start) startHour = Math.min(startHour, Math.floor(minutesOfDay(b.start) / 60));
      else startHour = 0;
      if (b.end < day.end) endHour = Math.max(endHour, Math.ceil(minutesOfDay(b.end) / 60));
      else endHour = 24;
    }
    const rangeStart = fromLocal(date, `${pad(startHour)}:00`);
    const rangeEnd = endHour >= 24 ? day.end : fromLocal(date, `${pad(endHour)}:00`);
    const span = rangeEnd - rangeStart;
    const pct = (ms) => ((Math.min(Math.max(ms, rangeStart), rangeEnd) - rangeStart) / span) * 100;
    const now = Date.now();
    const isToday = date === todayKey();

    const hours = [];
    for (let hr = startHour; hr <= endHour; hr++) hours.push(hr);
    const gridlines = () => [
      ...hours.map((hr) => h('div', { class: 'tl-gridline', style: { left: `${((hr - startHour) / (endHour - startHour)) * 100}%` } })),
      ...hours.slice(0, -1).map((hr) => h('div', { class: 'tl-gridline half', style: { left: `${((hr + 0.5 - startHour) / (endHour - startHour)) * 100}%` } })),
    ];

    const header = h(
      'div',
      { class: 'tl-row tl-head' },
      h('div', { class: 'tl-room' }, h('span', null, `${rooms.length} ${st.kind === 'desk' ? 'Arbeitsplätze' : 'Räume'}`)),
      h(
        'div',
        { class: 'tl-hours' },
        hours.map((hr, i) =>
          h(
            'div',
            { class: `tl-hour${i === 0 ? ' first' : i === hours.length - 1 ? ' last' : ''}`, style: { left: `${((hr - startHour) / (endHour - startHour)) * 100}%` } },
            `${pad(hr % 24)}:00`,
          ),
        ),
      ),
    );

    const rows = [header];
    let lastFloor = null;
    for (const room of rooms) {
      if (room.floorId !== lastFloor) {
        lastFloor = room.floorId;
        rows.push(h('div', { class: 'tl-group' }, roomPlace(room)));
      }
      const list = st.bookings.filter((b) => b.room.id === room.id);
      const track = h('div', { class: `tl-track${room.bookable ? '' : ' disabled'}`, dataset: { roomId: room.id } }, gridlines());
      if (isToday && now > rangeStart) track.append(h('div', { class: 'tl-past', style: { width: `${pct(now)}%` } }));
      for (const b of list) {
        const mine = b.isOwner || b.isAttendee;
        const cls = ['tl-block', b.type === 'block' ? 'block' : mine ? 'mine' : '', b.end <= now ? 'past' : ''].filter(Boolean).join(' ');
        const label = b.type === 'block' ? `Gesperrt: ${b.title}` : b.title;
        track.append(
          h(
            'button',
            {
              class: cls,
              type: 'button',
              style: { left: `${pct(b.start)}%`, width: `calc(${pct(b.end) - pct(b.start)}% - 2px)` },
              title: `${label}\n${fmt.time(b.start)}–${fmt.time(b.end)} · ${b.user.name}`,
              onClick: (e) => {
                e.stopPropagation();
                openBookingDetails(b);
              },
            },
            h('strong', null, label),
            h('span', null, `${fmt.time(b.start)}–${fmt.time(b.end)} · ${b.user.name}`),
          ),
        );
      }
      if (isToday && now >= rangeStart && now <= rangeEnd) track.append(h('div', { class: 'tl-now', style: { left: `${pct(now)}%` } }));
      if (room.bookable) attachSelection(track, room, { rangeStart, span, list });
      rows.push(
        h(
          'div',
          { class: 'tl-row' },
          h(
            'div',
            { class: 'tl-room' },
            h('strong', { title: room.name }, room.name),
            h('span', null, [room.kind === 'desk' ? 'Arbeitsplatz' : room.capacity ? `${room.capacity} Pers.` : 'Raum', room.bookable ? null : 'nicht buchbar'].filter(Boolean).join(' · ')),
          ),
          track,
        ),
      );
    }
    tlRoot.replaceChildren(h('div', { class: 'tl' }, rows));
  }

  function attachSelection(track, room, { rangeStart, span, list }) {
    const step = slotMinutes() * 60000;
    const timeAt = (clientX) => {
      const rect = track.getBoundingClientRect();
      const ratio = Math.min(Math.max((clientX - rect.left) / rect.width, 0), 1);
      return rangeStart + ratio * span;
    };
    let drag = null;
    track.addEventListener('pointerdown', (e) => {
      if (e.button !== 0 || e.target.closest('.tl-block')) return;
      const t = timeAt(e.clientX);
      drag = { x: e.clientX, t0: Math.floor(t / step) * step, t1: Math.ceil(t / step) * step, el: null, moved: false };
      track.setPointerCapture(e.pointerId);
    });
    track.addEventListener('pointermove', (e) => {
      if (!drag) return;
      if (Math.abs(e.clientX - drag.x) > 6) drag.moved = true;
      if (!drag.moved) return;
      const t = timeAt(e.clientX);
      const a = Math.min(drag.t0, Math.floor(t / step) * step);
      const b = Math.max(drag.t0 + step, Math.ceil(t / step) * step);
      drag.a = a;
      drag.b = b;
      if (!drag.el) {
        drag.el = h('div', { class: 'tl-selection' });
        track.append(drag.el);
      }
      drag.el.style.left = `${((a - rangeStart) / span) * 100}%`;
      drag.el.style.width = `${((b - a) / span) * 100}%`;
      drag.el.textContent = `${fmt.time(a)}–${fmt.time(b)}`;
    });
    const finish = (e) => {
      if (!drag) return;
      const d = drag;
      drag = null;
      d.el?.remove();
      if (e.type === 'pointercancel') return;
      let start;
      let end;
      if (d.moved && d.a !== undefined) {
        start = d.a;
        end = d.b;
      } else {
        start = d.t0;
        const nextBooking = list.filter((b) => b.start >= start + step).reduce((min, b) => Math.min(min, b.start), Infinity);
        end = Math.min(start + 60 * 60000, nextBooking, rangeStart + span);
        if (end <= start) end = start + step;
      }
      const now = Date.now();
      if (end <= now) {
        toast('Dieser Zeitraum liegt in der Vergangenheit.', { type: 'info', timeout: 3000 });
        return;
      }
      if (start < now) start = Math.max(start, currentSlot(now));
      openBookingDialog({ roomId: room.id, start, end });
    };
    track.addEventListener('pointerup', finish);
    track.addEventListener('pointercancel', finish);
  }

  let seq = 0;
  async function load() {
    const my = ++seq;
    const day = dayBounds(st.date);
    try {
      const list = await get(`/api/bookings?${qs({ from: day.start, to: day.end })}`);
      if (my !== seq) return;
      st.bookings = list;
    } catch (err) {
      if (my === seq) toast(err.message, { type: 'error' });
    }
    render();
  }

  await load();
  const reload = debounce(load, 250);
  const timer = setInterval(() => {
    if (st.date === todayKey()) render();
  }, 60000);
  const offs = [
    bus.on('bookings-changed', reload),
    bus.on('layout-changed', () => {
      floorSel.replaceChildren(h('option', { value: 'all' }, 'Alle Etagen'), ...sortedFloors().map((f) => h('option', { value: String(f.id) }, roomPlace({ floorId: f.id }))));
      if (st.floor !== 'all' && !floorById(st.floor)) st.floor = 'all';
      floorSel.value = String(st.floor);
      render();
    }),
  ];
  return () => {
    clearInterval(timer);
    offs.forEach((off) => off());
  };
}

