import { bus, get, post } from './api.js';
import { openBookingDetails, openBookingDialog } from './booking-dialog.js';
import { currentPath, initHostedNav, navigate, setRouter } from './nav.js';
import { isAdmin, loadLayout, state } from './state.js';
import { h, icon, toast } from './ui.js';
import { renderAdmin } from './views/admin.js';
import { renderLogin, renderSetup } from './views/auth.js';
import { renderBookings } from './views/bookings.js';
import { renderDashboard } from './views/dashboard.js';
import { renderEditor } from './views/editor.js';
import { renderFinder } from './views/finder.js';
import { renderNotifications } from './views/notifications.js';
import { renderProfile } from './views/profile.js';
import { renderTimeline } from './views/timeline.js';

const app = document.getElementById('app');

const NAV = [
  { path: '/', label: 'Übersicht', icon: 'home' },
  { path: '/finden', label: 'Raum finden', icon: 'map' },
  { path: '/belegung', label: 'Belegungsplan', icon: 'calendar' },
  { path: '/buchungen', label: 'Meine Buchungen', icon: 'list' },
  { path: '/admin', label: 'Verwaltung', icon: 'sliders', admin: true },
];

const ROUTES = [
  { re: /^\/$/, view: renderDashboard },
  { re: /^\/finden$/, view: renderFinder },
  { re: /^\/belegung$/, view: renderTimeline },
  { re: /^\/buchungen$/, view: renderBookings },
  { re: /^\/benachrichtigungen$/, view: renderNotifications },
  { re: /^\/profil$/, view: renderProfile },
  { re: /^\/admin(?:\/(gebaeude|benutzer|einstellungen|system|protokoll))?$/, view: renderAdmin, admin: true },
  { re: /^\/admin\/etage\/(\d+)$/, view: renderEditor, admin: true },
];

let cleanup = null;
let events = null;

// ------------------------------------------------------------------ Start

async function boot() {
  try {
    if (state.hosted) {
      // Web-Version in claude.ai: Die Identität kommt von claude.ai, es gibt keine eigene Anmeldung.
      initHostedNav();
      state.config = await get('/api/config');
      document.title = 'Raumplaner';
      applyMe(await get('/api/me'));
      await startApp();
      return;
    }
    state.config = await get('/api/config');
    document.title = state.config.orgName === 'Raumplaner' ? 'Raumplaner' : `Raumplaner · ${state.config.orgName}`;
    if (state.config.needsSetup) {
      renderSetup(app, onLoggedIn);
      return;
    }
    if (!state.config.loggedIn) {
      renderLogin(app, onLoggedIn);
      return;
    }
    applyMe(await get('/api/me'));
    await startApp();
  } catch (err) {
    if (err.status === 401) renderLogin(app, onLoggedIn);
    else showFatal(err);
  }
}

function applyMe(res) {
  state.me = res.user;
  state.calendarUrl = res.calendarUrl;
  state.unread = res.unreadCount;
}

async function onLoggedIn(res) {
  applyMe(res);
  state.config = await get('/api/config');
  await startApp();
}

async function startApp() {
  await loadLayout();
  renderShell();
  connectLive();
  setRouter(route);
  if (!state.hosted) {
    window.removeEventListener('hashchange', route);
    window.addEventListener('hashchange', route);
  }
  await route();
}

function showFatal(err) {
  app.replaceChildren(
    h(
      'div',
      { class: 'auth-wrap' },
      h(
        'div',
        { class: 'card auth-card' },
        h(
          'div',
          { class: 'card-body stack' },
          h('h1', null, 'Der Raumplaner ist gerade nicht erreichbar'),
          h('p', { class: 'muted' }, err?.message || 'Unbekannter Fehler.'),
          state.hosted ? null : h('button', { class: 'btn btn-primary', type: 'button', onClick: () => location.reload() }, icon('refresh'), 'Erneut versuchen'),
        ),
      ),
    ),
  );
}

bus.on('unread', (count) => {
  state.unread = count;
  updateBadge();
});

bus.on('unauthorized', () => {
  if (!state.me) return;
  state.me = null;
  events?.close();
  toast('Deine Sitzung ist abgelaufen. Bitte melde dich erneut an.', { type: 'info' });
  renderLogin(app, onLoggedIn);
});

// ------------------------------------------------------------------ Rahmen

let navEl;
let badgeEl;
let liveEl;

function renderShell() {
  navEl = h(
    'nav',
    { class: 'nav', 'aria-label': 'Hauptnavigation' },
    NAV.filter((n) => !n.admin || isAdmin()).map((n) =>
      h('a', { href: `#${n.path}`, dataset: { path: n.path }, onClick: () => navEl.classList.remove('open') }, icon(n.icon), h('span', null, n.label)),
    ),
  );
  badgeEl = h('span', { class: 'bell-badge', hidden: true });
  liveEl = h(
    'span',
    { class: 'live', title: 'Live-Verbindung: Änderungen erscheinen sofort' },
    h('span', { class: 'live-dot' }),
    h('span', { class: 'live-text' }, 'Live'),
  );
  const header = h(
    'header',
    { class: 'app-header' },
    h(
      'button',
      { class: 'btn btn-ghost btn-icon menu-toggle', type: 'button', 'aria-label': 'Menü', onClick: () => navEl.classList.toggle('open') },
      icon('menu'),
    ),
    h('a', { class: 'brand', href: '#/' }, h('span', { class: 'brand-mark' }, icon('door')), h('span', { class: 'brand-name' }, state.config.orgName)),
    navEl,
    h(
      'div',
      { class: 'header-actions' },
      liveEl,
      h(
        'a',
        { class: 'btn btn-ghost btn-icon bell', href: '#/benachrichtigungen', 'aria-label': 'Benachrichtigungen', title: 'Benachrichtigungen' },
        icon('bell'),
        badgeEl,
      ),
      h('a', { class: 'btn btn-ghost btn-icon', href: '#/profil', 'aria-label': 'Profil & Einstellungen', title: `${state.me.name} – Profil & Einstellungen` }, icon('user')),
      state.hosted
        ? null
        : h(
        'button',
        {
          class: 'btn btn-ghost btn-icon',
          type: 'button',
          'aria-label': 'Abmelden',
          title: 'Abmelden',
          onClick: async () => {
            try {
              await post('/api/auth/logout');
            } finally {
              location.hash = '#/';
              location.reload();
            }
          },
        },
        icon('logout'),
      ),
    ),
  );
  const main = h('main', { class: 'app-main', id: 'view', tabindex: '-1' });
  const readOnly =
    state.hosted && !state.config.canWrite
      ? h(
          'div',
          { class: 'notice warning', style: { maxWidth: '1440px', margin: '12px auto 0', width: 'calc(100% - 32px)' } },
          icon('eye'),
          h(
            'div',
            null,
            state.config.loggedIn
              ? 'Du kannst den Raumplaner ansehen, aber nicht buchen. Für Schreibzugriff wende dich an die Person, die ihn geteilt hat.'
              : 'Bitte melde dich in claude.ai an, um Räume zu buchen.',
          ),
        )
      : null;
  app.replaceChildren(...[header, readOnly, main].filter(Boolean));
  updateBadge();
}

export function updateBadge() {
  if (!badgeEl) return;
  badgeEl.hidden = !state.unread;
  badgeEl.textContent = state.unread > 99 ? '99+' : String(state.unread);
  document.title = `${state.unread ? `(${state.unread}) ` : ''}Raumplaner${state.config.orgName !== 'Raumplaner' ? ` · ${state.config.orgName}` : ''}`;
}

function setOnline(online) {
  state.online = online;
  if (!liveEl) return;
  liveEl.classList.toggle('offline', !online);
  liveEl.querySelector('.live-text').textContent = online ? 'Live' : 'Offline – verbinde neu …';
  liveEl.title = online ? 'Live-Verbindung: Änderungen erscheinen sofort' : 'Keine Verbindung zum Server. Es wird automatisch neu verbunden.';
}

// ------------------------------------------------------------------ Router

function parseHash() {
  const raw = currentPath();
  const [path, query = ''] = raw.split('?');
  return { path: path || '/', query: new URLSearchParams(query) };
}

async function route() {
  const { path, query } = parseHash();
  const view = document.getElementById('view');
  if (!view) return;

  // Deep-Link aus Benachrichtigungen: Buchungsdialog vorausgefüllt öffnen
  if (path === '/buchen') {
    const start = Number(query.get('start'));
    const end = Number(query.get('end'));
    const roomId = Number(query.get('room')) || undefined;
    navigate('/finden', { replace: true });
    setTimeout(() => openBookingDialog({ roomId, start: start || undefined, end: end || undefined }), 50);
    return;
  }

  const match = ROUTES.map((r) => ({ r, m: r.re.exec(path) })).find((x) => x.m);
  for (const a of navEl.querySelectorAll('a')) {
    const p = a.dataset.path;
    a.classList.toggle('active', p === '/' ? path === '/' : path.startsWith(p));
  }
  if (typeof cleanup === 'function') cleanup();
  cleanup = null;
  view.replaceChildren();

  if (!match || (match.r.admin && !isAdmin())) {
    view.append(h('div', { class: 'empty' }, h('h3', null, 'Seite nicht gefunden'), h('p', null, h('a', { href: '#/' }, 'Zur Übersicht'))));
    return;
  }
  try {
    cleanup = await match.r.view(view, { params: match.m.slice(1), query });
  } catch (err) {
    console.error(err);
    view.append(h('div', { class: 'notice danger' }, icon('alert'), h('div', null, `Die Ansicht konnte nicht geladen werden: ${err.message}`)));
  }
  if (query.get('id') && path === '/buchungen') openBookingDetails(query.get('id'));
  window.scrollTo(0, 0);
}

// ------------------------------------------------------------------ Live-Verbindung

function connectLive() {
  if (state.hosted) {
    // Web-Version: Live-Daten kommen direkt aus der claude.ai-Datenbank (siehe hosted/backend.js).
    state.hostedConnect({
      onStatus: setOnline,
      onNotification: handleNotification,
      onUnread: (count) => {
        state.unread = count;
        updateBadge();
      },
    });
    return;
  }
  events?.close();
  events = new EventSource('/api/events');
  let wasOffline = false;
  events.addEventListener('open', () => {
    setOnline(true);
    if (wasOffline) {
      // Nach einer Unterbrechung alles Relevante neu laden – so geht nichts verloren.
      bus.emit('bookings-changed', { reconnect: true });
      loadLayout().then(() => bus.emit('layout-changed', {})).catch(() => {});
    }
    wasOffline = false;
  });
  events.addEventListener('error', () => {
    wasOffline = true;
    setOnline(false);
  });
  events.addEventListener('hello', (e) => {
    const d = JSON.parse(e.data);
    state.unread = d.unreadCount;
    updateBadge();
  });
  events.addEventListener('unread', (e) => {
    state.unread = JSON.parse(e.data).unreadCount;
    updateBadge();
  });
  events.addEventListener('notification', (e) => handleNotification(JSON.parse(e.data)));
  events.addEventListener('bookings-changed', (e) => bus.emit('bookings-changed', JSON.parse(e.data)));
  events.addEventListener('layout-changed', () => {
    loadLayout()
      .then(() => bus.emit('layout-changed', {}))
      .catch(() => {});
  });
  events.addEventListener('config-changed', async () => {
    try {
      state.config = await get('/api/config');
    } catch {
      /* egal */
    }
  });
}

function handleNotification(n) {
  state.unread = n.unreadCount;
  updateBadge();
  bus.emit('notification', n);
  toast(n.title, {
    body: n.body,
    type: n.type === 'cancelled' ? 'error' : 'info',
    timeout: 9000,
    action: n.link ? { label: 'Ansehen', onClick: () => navigate(n.link) } : undefined,
  });
  desktopNotify(n);
}

export function desktopNotify(n) {
  try {
    if (state.hosted || !('Notification' in window) || Notification.permission !== 'granted') return;
    if (localStorage.getItem('rp.desktop') === 'off') return;
    if (!document.hidden) return; // sichtbar -> Toast reicht
    const note = new Notification(n.title, { body: n.body, tag: `rp-${n.id}`, icon: '/favicon.svg' });
    note.onclick = () => {
      window.focus();
      if (n.link) navigate(n.link);
      note.close();
    };
  } catch {
    /* Desktop-Benachrichtigungen nicht verfügbar */
  }
}

boot();
