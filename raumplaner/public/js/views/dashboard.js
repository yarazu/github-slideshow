import { bus, del, get, post, qs } from '../api.js';
import { navigate } from '../nav.js';
import { openBookingDetails, openBookingDialog, roomFacts } from '../booking-dialog.js';
import { bookableRooms, dateKey, dayBounds, fmt, isAdmin, loadLayout, minutesOfDay, nextSlot, roomPlace, state, todayKey } from '../state.js';
import { debounce, emptyState, h, icon, relativeTime, toast, toastError } from '../ui.js';

function greeting() {
  const hour = Math.floor(minutesOfDay(Date.now()) / 60);
  if (hour < 11) return 'Guten Morgen';
  if (hour < 18) return 'Guten Tag';
  return 'Guten Abend';
}

export function bookingListItem(b, { onOpen } = {}) {
  const now = Date.now();
  const ongoing = b.start <= now && b.end > now;
  const today = dateKey(b.start) === todayKey();
  return h(
    'li',
    { class: 'list-item clickable', tabindex: '0', onClick: () => onOpen(b), onKeydown: (e) => e.key === 'Enter' && onOpen(b) },
    h('div', { class: 'time-box' }, h('strong', null, fmt.time(b.start)), h('span', null, today ? 'heute' : fmt.date(b.start).slice(0, 10))),
    h(
      'div',
      { class: 'list-main' },
      h('div', { class: 'list-title' }, b.title),
      h(
        'div',
        { class: 'list-meta' },
        h('span', null, icon('pin'), `${b.room.name} · ${b.floor.name}`),
        h('span', null, icon('clock'), `${fmt.time(b.start)}–${fmt.time(b.end)}`),
        b.isOwner ? null : h('span', null, icon('user'), `von ${b.user.name}`),
        b.attendees.length ? h('span', null, icon('users'), `${b.attendees.length + 1}`) : null,
      ),
    ),
    ongoing ? h('span', { class: 'badge free' }, 'läuft') : null,
    b.seriesId ? h('span', { class: 'badge primary', title: 'Serientermin' }, icon('repeat')) : null,
  );
}

export async function renderDashboard(root) {
  const first = state.me.name.split(' ')[0];
  const upcomingCard = h('div', { class: 'card' });
  const freeCard = h('div', { class: 'card' });
  const notifCard = h('div', { class: 'card' });
  const watchCard = h('div', { class: 'card', hidden: true });
  const hasRooms = bookableRooms().length > 0;

  root.append(
    h(
      'div',
      { class: 'page-head' },
      h('div', null, h('h1', null, `${greeting()}, ${first}!`), h('p', null, fmt.dateLong(Date.now()))),
      h(
        'div',
        { class: 'row' },
        h('a', { class: 'btn', href: '#/finden' }, icon('map'), 'Raum finden'),
        h('button', { class: 'btn btn-primary', type: 'button', disabled: !hasRooms, onClick: () => openBookingDialog() }, icon('plus'), 'Raum buchen'),
      ),
    ),
  );

  if (!hasRooms) {
    root.append(
      h(
        'div',
        { class: 'card', style: { marginBottom: '16px' } },
        isAdmin()
          ? emptyState('layers', 'Noch keine Räume hinterlegt', 'Lege Gebäude, Etagen und Räume an – oder lade ein Beispielgebäude, um alles auszuprobieren.', [
              h(
                'button',
                {
                  class: 'btn',
                  type: 'button',
                  onClick: async (e) => {
                    e.currentTarget.disabled = true;
                    try {
                      await post('/api/admin/demo', { withBookings: true });
                      await loadLayout();
                      toast('Beispielgebäude geladen', { type: 'success', body: 'Schau dir den Lageplan unter „Raum finden“ an.' });
                      navigate('/finden');
                    } catch (err) {
                      toastError(err);
                      e.currentTarget.disabled = false;
                    }
                  },
                },
                icon('download'),
                'Beispielgebäude laden',
              ),
              h('a', { class: 'btn btn-primary', href: '#/admin/gebaeude' }, icon('plus'), 'Gebäude anlegen'),
            ])
          : emptyState('layers', 'Noch keine Räume hinterlegt', 'Sobald die Administration Räume angelegt hat, kannst du hier buchen.'),
      ),
    );
  }

  root.append(h('div', { class: 'grid-2' }, h('div', { class: 'stack' }, upcomingCard, watchCard), h('div', { class: 'stack' }, freeCard, notifCard)));

  async function loadUpcoming() {
    try {
      const list = (await get('/api/bookings/mine')).slice(0, 6);
      upcomingCard.replaceChildren(
        h('div', { class: 'card-head' }, h('h2', null, icon('calendar'), 'Meine nächsten Termine'), h('a', { href: '#/buchungen', class: 'small' }, 'Alle anzeigen')),
        list.length
          ? h('ul', { class: 'list card-body flush' }, list.map((b) => bookingListItem(b, { onOpen: (x) => openBookingDetails(x) })))
          : h('div', { class: 'card-body' }, emptyState('calendar', 'Keine anstehenden Termine', hasRooms ? 'Buche einen Raum – er erscheint dann hier.' : null)),
      );
    } catch (err) {
      upcomingCard.replaceChildren(h('div', { class: 'card-body' }, h('p', { class: 'form-error' }, err.message)));
    }
  }

  async function loadFree() {
    if (!hasRooms) {
      freeCard.hidden = true;
      return;
    }
    const now = Date.now();
    const start = Math.ceil(now / 60000) * 60000; // ab jetzt (minutengenau)
    const { end: dayEnd } = dayBounds(todayKey());
    try {
      const [avail, today] = await Promise.all([
        get(`/api/availability?${qs({ start: now, end: now + 30 * 60000 })}`),
        get(`/api/bookings?${qs({ from: now, to: dayEnd })}`),
      ]);
      const rooms = bookableRooms().filter((r) => r.kind === 'room' && !avail.busy[r.id]);
      const nextStart = (roomId) => today.filter((b) => b.room.id === roomId && b.start >= now).reduce((min, b) => Math.min(min, b.start), Infinity);
      rooms.sort((a, b) => nextStart(b.id) - nextStart(a.id) || (b.capacity || 0) - (a.capacity || 0));
      freeCard.replaceChildren(
        h('div', { class: 'card-head' }, h('h2', null, icon('door'), 'Jetzt frei'), h('span', { class: 'badge free' }, `${rooms.length} Räume`)),
        rooms.length
          ? h(
              'ul',
              { class: 'list card-body flush' },
              rooms.slice(0, 6).map((r) => {
                const ns = nextStart(r.id);
                return h(
                  'li',
                  { class: 'list-item' },
                  h(
                    'div',
                    { class: 'list-main' },
                    h('div', { class: 'list-title' }, r.name),
                    h('div', { class: 'list-meta' }, h('span', null, roomPlace(r)), h('span', null, roomFacts(r))),
                  ),
                  h('span', { class: 'badge free' }, ns === Infinity ? 'heute frei' : `frei bis ${fmt.time(ns)}`),
                  h(
                    'button',
                    {
                      class: 'btn btn-sm',
                      type: 'button',
                      title: 'Ab jetzt buchen',
                      onClick: () => openBookingDialog({ roomId: r.id, start, end: Math.min(nextSlot(start + 45 * 60000), ns) }),
                    },
                    'Buchen',
                  ),
                );
              }),
            )
          : h('div', { class: 'card-body' }, emptyState('door', 'Gerade ist alles belegt', 'Im Belegungsplan siehst du, wann wieder etwas frei wird.')),
        rooms.length > 6
          ? h('div', { style: { padding: '10px 18px 14px', borderTop: '1px solid var(--border)' } }, h('a', { href: '#/finden', class: 'small' }, `${rooms.length - 6} weitere freie Räume im Lageplan ansehen`))
          : null,
      );
    } catch (err) {
      freeCard.replaceChildren(h('div', { class: 'card-body' }, h('p', { class: 'form-error' }, err.message)));
    }
  }

  async function loadNotifications() {
    try {
      const { items, unreadCount } = await get('/api/notifications?limit=4');
      bus.emit('unread', unreadCount);
      notifCard.replaceChildren(
        h(
          'div',
          { class: 'card-head' },
          h('h2', null, icon('bell'), 'Benachrichtigungen'),
          h('a', { href: '#/benachrichtigungen', class: 'small' }, unreadCount ? `${unreadCount} ungelesen` : 'Alle anzeigen'),
        ),
        items.length
          ? h(
              'div',
              { class: 'card-body flush' },
              items.map((n) =>
                h(
                  'div',
                  { class: `notif${n.read ? '' : ' unread'}`, onClick: () => navigate(n.link || '/benachrichtigungen') },
                  h(
                    'div',
                    { style: { minWidth: '0' } },
                    h('div', { class: 'notif-title' }, n.title),
                    h('div', { class: 'notif-body' }, n.body),
                    h('div', { class: 'notif-time' }, relativeTime(n.createdAt) || fmt.dateTime(n.createdAt)),
                  ),
                ),
              ),
            )
          : h('div', { class: 'card-body' }, emptyState('bell', 'Alles ruhig', 'Einladungen, Änderungen und Erinnerungen erscheinen hier – und auf Wunsch per E-Mail.')),
      );
    } catch (err) {
      notifCard.replaceChildren(h('div', { class: 'card-body' }, h('p', { class: 'form-error' }, err.message)));
    }
  }

  async function loadWatches() {
    try {
      const watches = await get('/api/watches');
      watchCard.hidden = !watches.length;
      if (!watches.length) return;
      watchCard.replaceChildren(
        h('div', { class: 'card-head' }, h('h2', null, icon('eye'), 'Meine Raum-Wünsche')),
        h('p', { class: 'muted small', style: { padding: '4px 18px 0' } }, 'Du wirst benachrichtigt, sobald der Raum frei wird.'),
        h(
          'ul',
          { class: 'list card-body flush' },
          watches.map((w) =>
            h(
              'li',
              { class: 'list-item' },
              h('div', { class: 'list-main' }, h('div', { class: 'list-title' }, w.roomName), h('div', { class: 'list-meta' }, fmt.range(w.start, w.end))),
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

  const refresh = debounce(() => {
    loadUpcoming();
    loadFree();
    loadWatches();
  }, 300);
  loadUpcoming();
  loadFree();
  loadNotifications();
  loadWatches();
  const timer = setInterval(loadFree, 60000);
  const offs = [bus.on('bookings-changed', refresh), bus.on('notification', () => (loadNotifications(), loadWatches()))];
  return () => {
    clearInterval(timer);
    offs.forEach((off) => off());
  };
}
