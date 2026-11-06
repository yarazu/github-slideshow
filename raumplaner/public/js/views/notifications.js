import { bus, get, post } from '../api.js';
import { fmt } from '../state.js';
import { emptyState, h, icon, relativeTime, toastError } from '../ui.js';

const TYPE_ICON = {
  invite: 'mail',
  updated: 'edit',
  cancelled: 'x',
  reminder: 'clock',
  watch: 'eye',
  test: 'check',
};

export async function renderNotifications(root) {
  const listEl = h('div', { class: 'card-body flush' });
  const moreBtn = h('button', { class: 'btn btn-ghost', type: 'button', hidden: true }, 'Ältere laden');
  const readAllBtn = h('button', { class: 'btn', type: 'button' }, icon('check'), 'Alle als gelesen markieren');
  let items = [];

  root.append(
    h(
      'div',
      { class: 'page-head' },
      h(
        'div',
        null,
        h('h1', null, 'Benachrichtigungen'),
        h('p', null, 'Einladungen, Änderungen, Absagen, Erinnerungen und freie Wunschräume – alles an einem Ort.'),
      ),
      h('div', { class: 'row' }, h('a', { class: 'btn btn-ghost', href: '#/profil' }, icon('sliders'), 'Einstellungen'), readAllBtn),
    ),
    h('div', { class: 'card' }, listEl, h('div', { class: 'row', style: { justifyContent: 'center', padding: '8px' } }, moreBtn)),
  );

  function render() {
    if (!items.length) {
      listEl.replaceChildren(
        h(
          'div',
          { class: 'card-body' },
          emptyState('bell', 'Keine Benachrichtigungen', 'Sobald dich jemand einlädt, ein Termin geändert wird oder eine Erinnerung ansteht, erscheint es hier.'),
        ),
      );
      return;
    }
    listEl.replaceChildren(
      ...items.map((n) =>
        h(
          'div',
          {
            class: `notif${n.read ? '' : ' unread'}`,
            role: 'link',
            tabindex: '0',
            onClick: () => open(n),
            onKeydown: (e) => e.key === 'Enter' && open(n),
          },
          h('div', { class: 'notif-icon' }, icon(TYPE_ICON[n.type] || 'bell')),
          h(
            'div',
            { style: { minWidth: '0', flex: '1' } },
            h('div', { class: 'notif-title' }, n.title),
            n.body ? h('div', { class: 'notif-body' }, n.body) : null,
            h('div', { class: 'notif-time' }, relativeTime(n.createdAt) || fmt.dateTime(n.createdAt)),
          ),
        ),
      ),
    );
  }

  async function markRead(ids) {
    try {
      const res = await post('/api/notifications/read', ids ? { ids } : { all: true });
      bus.emit('unread', res.unreadCount);
    } catch (err) {
      toastError(err);
    }
  }

  async function open(n) {
    if (!n.read) {
      n.read = true;
      render();
      await markRead([n.id]);
    }
    if (n.link) location.hash = n.link;
    else if (n.bookingId) location.hash = `#/buchungen?id=${n.bookingId}`;
  }

  async function load(before) {
    try {
      const res = await get(`/api/notifications?limit=50${before ? `&before=${before}` : ''}`);
      items = before ? [...items, ...res.items] : res.items;
      moreBtn.hidden = res.items.length < 50;
      bus.emit('unread', res.unreadCount);
      render();
    } catch (err) {
      listEl.replaceChildren(h('div', { class: 'card-body' }, h('p', { class: 'form-error' }, err.message)));
    }
  }

  readAllBtn.addEventListener('click', async () => {
    await markRead(null);
    items = items.map((n) => ({ ...n, read: true }));
    render();
  });
  moreBtn.addEventListener('click', () => load(items[items.length - 1]?.id));

  await load();
  const off = bus.on('notification', () => load());
  return off;
}
