import { bus, del, get } from '../api.js';
import { openBookingDetails, openBookingDialog } from '../booking-dialog.js';
import { addDays, dateKey, fmt, fromLocal, todayKey } from '../state.js';
import { debounce, emptyState, h, icon, toastError } from '../ui.js';
import { bookingListItem } from './dashboard.js';

function dayHeading(key) {
  if (key === todayKey()) return 'Heute';
  if (key === addDays(todayKey(), 1)) return 'Morgen';
  if (key === addDays(todayKey(), -1)) return 'Gestern';
  return fmt.dateLong(fromLocal(key, '12:00'));
}

export async function renderBookings(root) {
  let scope = 'upcoming';
  const list = h('div', { class: 'card' });
  const watchCard = h('div', { class: 'card', hidden: true });
  const tabs = h(
    'div',
    { class: 'tabs', role: 'tablist' },
    [
      ['upcoming', 'Anstehend'],
      ['past', 'Vergangen'],
    ].map(([k, label]) =>
      h(
        'button',
        {
          type: 'button',
          role: 'tab',
          class: k === scope ? 'active' : '',
          dataset: { scope: k },
          onClick: () => {
            scope = k;
            for (const t of tabs.children) t.classList.toggle('active', t.dataset.scope === k);
            load();
          },
        },
        label,
      ),
    ),
  );

  root.append(
    h(
      'div',
      { class: 'page-head' },
      h('div', null, h('h1', null, 'Meine Buchungen'), h('p', null, 'Alles, was du gebucht hast oder wozu du eingeladen bist.')),
      h(
        'div',
        { class: 'row' },
        h('a', { class: 'btn', href: '#/profil', title: 'Kalender-Abo für Outlook, Google & Co.' }, icon('link'), 'Kalender-Abo'),
        h('button', { class: 'btn btn-primary', type: 'button', onClick: () => openBookingDialog() }, icon('plus'), 'Raum buchen'),
      ),
    ),
    tabs,
    h('div', { class: 'stack' }, list, watchCard),
  );

  async function load() {
    try {
      const items = await get(`/api/bookings/mine?scope=${scope}`);
      if (!items.length) {
        list.replaceChildren(
          h(
            'div',
            { class: 'card-body' },
            emptyState(
              'calendar',
              scope === 'upcoming' ? 'Keine anstehenden Buchungen' : 'Noch keine vergangenen Buchungen',
              scope === 'upcoming' ? 'Unter „Raum finden“ siehst du sofort, was frei ist.' : null,
              scope === 'upcoming' ? [h('a', { class: 'btn btn-primary', href: '#/finden' }, icon('map'), 'Raum finden')] : [],
            ),
          ),
        );
        return;
      }
      const groups = new Map();
      for (const b of items) {
        const key = dateKey(b.start);
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(b);
      }
      const parts = [];
      for (const [key, bookings] of groups) {
        parts.push(h('div', { class: 'day-label' }, dayHeading(key)));
        parts.push(h('ul', { class: 'list' }, bookings.map((b) => bookingListItem(b, { onOpen: (x) => openBookingDetails(x, { onChange: load }) }))));
      }
      list.replaceChildren(...parts);
    } catch (err) {
      list.replaceChildren(h('div', { class: 'card-body' }, h('p', { class: 'form-error' }, err.message)));
    }
  }

  async function loadWatches() {
    try {
      const watches = await get('/api/watches');
      watchCard.hidden = !watches.length;
      watchCard.replaceChildren(
        h('div', { class: 'card-head' }, h('h2', null, icon('eye'), 'Raum-Wünsche'), h('span', { class: 'badge primary' }, String(watches.length))),
        h('p', { class: 'muted small', style: { padding: '4px 18px 0' } }, 'Sobald einer dieser Zeiträume frei wird, bekommst du eine Benachrichtigung.'),
        h(
          'ul',
          { class: 'list card-body flush' },
          watches.map((w) =>
            h(
              'li',
              { class: 'list-item' },
              h(
                'div',
                { class: 'list-main' },
                h('div', { class: 'list-title' }, w.roomName),
                h('div', { class: 'list-meta' }, h('span', null, `${w.floorName} · ${w.buildingName}`), h('span', null, fmt.range(w.start, w.end))),
              ),
              h(
                'button',
                {
                  class: 'btn btn-ghost btn-sm',
                  type: 'button',
                  onClick: async () => {
                    try {
                      await del(`/api/watches/${w.id}`);
                      loadWatches();
                    } catch (err) {
                      toastError(err);
                    }
                  },
                },
                icon('trash'),
                'Entfernen',
              ),
            ),
          ),
        ),
      );
    } catch {
      watchCard.hidden = true;
    }
  }

  await Promise.all([load(), loadWatches()]);
  const reload = debounce(() => {
    load();
    loadWatches();
  }, 250);
  const offs = [bus.on('bookings-changed', reload), bus.on('notification', reload)];
  return () => offs.forEach((off) => off());
}

