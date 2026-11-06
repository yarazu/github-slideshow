import { state } from './state.js';

/**
 * Navigation für beide Bauformen.
 * - Server-Version: klassisches Hash-Routing (#/finden?floor=2).
 * - Web-Version in claude.ai: dort dürfen in der Adresse nur einfache Namen stehen (#finden).
 *   Die vollständige Route (inkl. Parameter) wird deshalb intern gehalten.
 */
let router = null;
let current = '/';

const TO_NAME = [
  [/^\/$/, () => ''],
  [/^\/admin\/etage\/(\d+)$/, (m) => `etage-${m[1]}`],
  [/^\/admin\/([a-z]+)$/, (m) => `verwaltung-${m[1]}`],
  [/^\/admin$/, () => 'verwaltung'],
  [/^\/([a-z]+)$/, (m) => m[1]],
];

const FROM_NAME = [
  [/^etage-(\d+)$/, (m) => `/admin/etage/${m[1]}`],
  [/^verwaltung-([a-z]+)$/, (m) => `/admin/${m[1]}`],
  [/^verwaltung$/, () => '/admin'],
  [/^([a-z]+)$/, (m) => `/${m[1]}`],
];

function nameFor(path) {
  const p = path.split('?')[0];
  for (const [re, fn] of TO_NAME) {
    const m = re.exec(p);
    if (m) return fn(m);
  }
  return '';
}

function pathFromName(name) {
  for (const [re, fn] of FROM_NAME) {
    const m = re.exec(name);
    if (m) return fn(m);
  }
  return '/';
}

export function setRouter(fn) {
  router = fn;
}

/** Aktuelle Route inkl. Parameter, z. B. "/buchungen?id=12". */
export function currentPath() {
  if (!state.hosted) return location.hash.replace(/^#/, '') || '/';
  return current;
}

/** Web-Version: Links mit href="#/…" abfangen und die Startansicht aus der Adresse lesen. */
export function initHostedNav() {
  current = pathFromName((location.hash || '').replace(/^#/, ''));
  document.addEventListener('click', (e) => {
    const a = e.target.closest?.('a[href^="#/"]');
    if (!a || e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey) return;
    e.preventDefault();
    navigate(a.getAttribute('href'));
  });
  window.addEventListener('hashchange', () => {
    const p = pathFromName(location.hash.replace(/^#/, ''));
    if (p.split('?')[0] !== current.split('?')[0]) {
      current = p;
      router?.();
    }
  });
}

export function navigate(target, { replace = false } = {}) {
  const path = String(target || '/').replace(/^#/, '') || '/';
  if (!state.hosted) {
    if (replace) location.replace(`#${path}`);
    else location.hash = `#${path}`;
    return;
  }
  current = path;
  const name = nameFor(path);
  try {
    if (location.hash.replace(/^#/, '') !== name) {
      if (name) location.hash = name;
      else history.replaceState(null, '', location.pathname + location.search);
    }
  } catch {
    /* Adresse lässt sich in dieser Ansicht nicht ändern – Route gilt trotzdem */
  }
  router?.();
}
