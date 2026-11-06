/**
 * Kleine UI-Bibliothek: DOM-Erzeugung ohne innerHTML für Nutzerdaten (Schutz vor XSS),
 * Icons, Toasts und Dialoge.
 */

const PROPS = new Set(['value', 'checked', 'selected', 'disabled', 'indeterminate', 'multiple']);

function append(el, children) {
  for (const c of children.flat(Infinity)) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
}

function applyAttrs(el, attrs, isSvg) {
  const deferred = [];
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') el.setAttribute('class', Array.isArray(v) ? v.filter(Boolean).join(' ') : v);
    else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
    else if (k === 'dataset') Object.assign(el.dataset, v);
    else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2).toLowerCase(), v);
    else if (!isSvg && PROPS.has(k)) deferred.push([k, v]);
    else if (k === 'ref' && typeof v === 'function') deferred.push([k, v]);
    else el.setAttribute(k, v === true ? '' : String(v));
  }
  return deferred;
}

/** HTML-Element erzeugen: h('button', { class: 'btn', onClick }, 'Text') */
export function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  const deferred = applyAttrs(el, attrs, false);
  append(el, children);
  for (const [k, v] of deferred) {
    if (k === 'ref') v(el);
    else el[k] = v;
  }
  return el;
}

const SVG_NS = 'http://www.w3.org/2000/svg';

/** SVG-Element erzeugen */
export function s(tag, attrs, ...children) {
  const el = document.createElementNS(SVG_NS, tag);
  applyAttrs(el, attrs, true);
  append(el, children);
  return el;
}

// Icon-Pfade nach Feather Icons (MIT-Lizenz, https://feathericons.com)
const ICONS = {
  home: '<path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/>',
  map: '<polygon points="1 6 1 22 8 18 16 22 23 18 23 2 16 6 8 2 1 6"/><line x1="8" y1="2" x2="8" y2="18"/><line x1="16" y1="6" x2="16" y2="22"/>',
  calendar: '<rect x="3" y="4" width="18" height="18" rx="2" ry="2"/><line x1="16" y1="2" x2="16" y2="6"/><line x1="8" y1="2" x2="8" y2="6"/><line x1="3" y1="10" x2="21" y2="10"/>',
  list: '<line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/>',
  bell: '<path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 0 1-3.46 0"/>',
  sliders: '<line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/><line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/><line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/><line x1="1" y1="14" x2="7" y2="14"/><line x1="9" y1="8" x2="15" y2="8"/><line x1="17" y1="16" x2="23" y2="16"/>',
  user: '<path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/>',
  users: '<path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
  logout: '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/>',
  plus: '<line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>',
  minus: '<line x1="5" y1="12" x2="19" y2="12"/>',
  x: '<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>',
  check: '<polyline points="20 6 9 17 4 12"/>',
  left: '<polyline points="15 18 9 12 15 6"/>',
  right: '<polyline points="9 18 15 12 9 6"/>',
  trash: '<polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>',
  edit: '<path d="M12 20h9"/><path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z"/>',
  clock: '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
  search: '<circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/>',
  menu: '<line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="18" x2="21" y2="18"/>',
  pointer: '<path d="M3 3l7.07 16.97 2.51-7.39 7.39-2.51L3 3z"/><path d="M13 13l6 6"/>',
  square: '<rect x="3" y="3" width="18" height="18" rx="2" ry="2"/>',
  polygon: '<polygon points="12 2 22 9 18 22 6 22 2 9 12 2"/>',
  copy: '<rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
  upload: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/>',
  download: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/>',
  grid: '<rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/>',
  zoomIn: '<circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/><line x1="11" y1="8" x2="11" y2="14"/><line x1="8" y1="11" x2="14" y2="11"/>',
  zoomOut: '<circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/><line x1="8" y1="11" x2="14" y2="11"/>',
  lock: '<rect x="3" y="11" width="18" height="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
  repeat: '<polyline points="17 1 21 5 17 9"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><polyline points="7 23 3 19 7 15"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/>',
  pin: '<path d="M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0 1 18 0z"/><circle cx="12" cy="10" r="3"/>',
  alert: '<path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>',
  info: '<circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/>',
  layers: '<polygon points="12 2 2 7 12 12 22 7 12 2"/><polyline points="2 17 12 22 22 17"/><polyline points="2 12 12 17 22 12"/>',
  mail: '<path d="M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z"/><polyline points="22,6 12,13 2,6"/>',
  monitor: '<rect x="2" y="3" width="20" height="14" rx="2" ry="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/>',
  eye: '<path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/>',
  door: '<path d="M3 21h18"/><path d="M5 21V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v17"/><line x1="13" y1="12" x2="13.01" y2="12"/>',
  database: '<ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"/><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/>',
  refresh: '<polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/>',
  stop: '<rect x="5" y="5" width="14" height="14" rx="2"/>',
  link: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
};

export function icon(name, cls = '') {
  const el = document.createElementNS(SVG_NS, 'svg');
  el.setAttribute('viewBox', '0 0 24 24');
  el.setAttribute('fill', 'none');
  el.setAttribute('stroke', 'currentColor');
  el.setAttribute('stroke-width', '2');
  el.setAttribute('stroke-linecap', 'round');
  el.setAttribute('stroke-linejoin', 'round');
  el.setAttribute('aria-hidden', 'true');
  el.setAttribute('class', `icon ${cls}`.trim());
  el.innerHTML = ICONS[name] || ICONS.info; // statische, vertrauenswürdige Pfade
  return el;
}

// ------------------------------------------------------------------ Toasts

export function toast(title, { body, type = 'info', timeout = 5000, action } = {}) {
  const root = document.getElementById('toasts');
  if (!root) return;
  const close = () => el.remove();
  const el = h(
    'div',
    { class: `toast ${type}`, role: type === 'error' ? 'alert' : 'status' },
    icon(type === 'success' ? 'check' : type === 'error' ? 'alert' : 'bell'),
    h(
      'div',
      { style: { minWidth: '0' } },
      h('div', { class: 'toast-title' }, title),
      body ? h('div', { class: 'toast-body' }, body) : null,
      action ? h('button', { class: 'btn-link btn small', type: 'button', onClick: () => (close(), action.onClick()) }, action.label) : null,
    ),
    h('button', { class: 'btn btn-ghost btn-icon btn-sm toast-close', type: 'button', 'aria-label': 'Schließen', onClick: close }, icon('x')),
  );
  root.append(el);
  while (root.children.length > 4) root.firstChild.remove();
  if (timeout) setTimeout(close, timeout);
}

export function toastError(err, fallback = 'Das hat nicht geklappt.') {
  toast(err?.message || fallback, { type: 'error', timeout: 8000 });
}

// ------------------------------------------------------------------ Dialoge

/**
 * Öffnet einen modalen Dialog (natives <dialog>: Fokusfalle und Escape inklusive).
 * Gibt { el, body, close, setBusy } zurück.
 */
export function openDialog({ title, content, actions = [], wide = false, onClose } = {}) {
  const body = h('div', { class: 'dialog-body' }, content);
  const foot = actions.length ? h('div', { class: 'dialog-foot' }, actions) : null;
  const dlg = h(
    'dialog',
    { class: `dialog${wide ? ' wide' : ''}`, 'aria-label': typeof title === 'string' ? title : undefined },
    h(
      'div',
      { class: 'dialog-inner' },
      h(
        'div',
        { class: 'dialog-head' },
        h('h2', null, title),
        h('button', { class: 'btn btn-ghost btn-icon btn-sm', type: 'button', 'aria-label': 'Schließen', onClick: () => dlg.close() }, icon('x')),
      ),
      body,
      foot,
    ),
  );
  dlg.addEventListener('close', () => {
    dlg.remove();
    onClose?.();
  });
  dlg.addEventListener('click', (e) => {
    if (e.target === dlg) dlg.close();
  });
  document.body.append(dlg);
  dlg.showModal();
  return {
    el: dlg,
    body,
    foot,
    close: () => dlg.open && dlg.close(),
    setActions(list) {
      if (foot) foot.replaceChildren(...list);
    },
  };
}

/** Bestätigungsdialog – liefert true/false. */
export function confirmDialog(message, { title = 'Bist du sicher?', confirmLabel = 'Bestätigen', danger = false, details } = {}) {
  return new Promise((resolve) => {
    let result = false;
    const d = openDialog({
      title,
      content: h('div', { class: 'stack-sm' }, h('p', null, message), details ? h('p', { class: 'muted small' }, details) : null),
      actions: [
        h('button', { class: 'btn', type: 'button', onClick: () => d.close() }, 'Abbrechen'),
        h(
          'button',
          {
            class: `btn ${danger ? 'btn-danger' : 'btn-primary'}`,
            type: 'button',
            onClick: () => {
              result = true;
              d.close();
            },
          },
          confirmLabel,
        ),
      ],
      onClose: () => resolve(result),
    });
  });
}

/** Eingabedialog für einen Text – liefert den Wert oder null. */
export function promptDialog(message, { title = 'Eingabe', label = '', value = '', type = 'text', confirmLabel = 'OK', placeholder = '' } = {}) {
  return new Promise((resolve) => {
    let result = null;
    const input = h('input', { class: 'input', type, value, placeholder, 'aria-label': label || message });
    const submit = (e) => {
      e?.preventDefault();
      result = input.value;
      d.close();
    };
    const d = openDialog({
      title,
      content: h('form', { class: 'form', onSubmit: submit }, h('p', null, message), h('div', { class: 'field' }, label ? h('label', null, label) : null, input)),
      actions: [
        h('button', { class: 'btn', type: 'button', onClick: () => d.close() }, 'Abbrechen'),
        h('button', { class: 'btn btn-primary', type: 'button', onClick: submit }, confirmLabel),
      ],
      onClose: () => resolve(result),
    });
    setTimeout(() => input.focus(), 30);
  });
}

// ------------------------------------------------------------------ Kleinkram

export function field(label, control, hint) {
  const id = control.id || `f-${Math.random().toString(36).slice(2, 9)}`;
  control.id = id;
  return h('div', { class: 'field' }, h('label', { for: id }, label), control, hint ? h('div', { class: 'hint' }, hint) : null);
}

export function emptyState(iconName, title, text, actions = []) {
  return h('div', { class: 'empty' }, icon(iconName), h('h3', null, title), text ? h('p', null, text) : null, actions.length ? h('div', { class: 'row' }, actions) : null);
}

export function debounce(fn, ms = 250) {
  let t;
  return (...args) => {
    clearTimeout(t);
    t = setTimeout(() => fn(...args), ms);
  };
}

export function relativeTime(ms) {
  const diff = Date.now() - ms;
  const min = Math.round(diff / 60000);
  if (Math.abs(min) < 1) return 'gerade eben';
  if (min > 0 && min < 60) return `vor ${min} Min.`;
  const hrs = Math.round(min / 60);
  if (min > 0 && hrs < 24) return `vor ${hrs} Std.`;
  const days = Math.round(hrs / 24);
  if (min > 0 && days < 7) return days === 1 ? 'gestern' : `vor ${days} Tagen`;
  return null;
}

export async function copyToClipboard(text) {
  try {
    await navigator.clipboard.writeText(text);
    toast('In die Zwischenablage kopiert', { type: 'success', timeout: 2500 });
  } catch {
    toast('Kopieren nicht möglich – bitte manuell markieren und kopieren.', { type: 'error' });
  }
}

export function setBusy(button, busy) {
  if (!button) return;
  button.disabled = busy;
  button.setAttribute('aria-busy', busy ? 'true' : 'false');
  button.style.cursor = busy ? 'progress' : '';
}
