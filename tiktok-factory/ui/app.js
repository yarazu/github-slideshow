// TikTok Factory – Logik der Oberfläche (ohne Build-Schritt, ohne Framework).
// Die Seite spricht nur mit dem lokalen Server der App (/api/…); Fenster-Befehle gehen an pywebview.

const BOOT = JSON.parse(document.getElementById('boot').textContent);
const html = document.documentElement;
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const icon = (id, cls = '') => `<svg class="ico ${cls}"><use href="#${id}"/></svg>`;
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
const media = (folder, file) => `/media/${encodeURIComponent(folder)}/${file}?t=${encodeURIComponent(BOOT.token)}`;

// Vorschau im Browser: ?backdrop=clear|vibrancy|opaque&platform=darwin&shell=desktop zeigt die Fenster-Varianten
if (BOOT.shell.mode === 'browser') {
  const q = new URLSearchParams(location.search);
  if (q.get('backdrop')) BOOT.shell.backdrop = q.get('backdrop');
  if (q.get('platform')) BOOT.shell.platform = q.get('platform');
  if (q.get('shell') === 'desktop') BOOT.shell.mode = 'desktop';
}

const S = {
  data: null,
  view: 'studio',
  form: { mode: 'niche', niche: '', count: 1, topic: '', lang: 'de', voice: '', music: true, scriptOnly: false,
          trendNumbers: [], script: null, scriptInfo: null, voiceUpload: null, whisper: true },
  jobs: [], rev: -1, seq: 0, focus: null, stageKey: null, offline: false, compact: false,
};

const NICHE_UI = {
  psychologie: { label: 'Psychologie', hue: '#9b7bff' },
  geschichte: { label: 'Geschichte & Rätsel', hue: '#e0a458' },
  weltraum: { label: 'Weltraum', hue: '#4f8bff' },
  tiere: { label: 'Tierfakten', hue: '#3ecf8e' },
  wusstestdu: { label: 'Wusstest du?', hue: '#f5b93a' },
  stoizismus: { label: 'Stoizismus', hue: '#8fa3bb' },
  geld: { label: 'Geld-Wissen', hue: '#2ec4b6' },
  technik: { label: 'Technik & KI', hue: '#38b6ff' },
  trend: { label: 'Trends', hue: '#ff5fa8' },
};
const ACCENTS = {
  aurora: ['#45c9ff', '#8a6bff', '#ff5fa8'],
  sunset: ['#ffb347', '#ff6a5c', '#d94dff'],
  mint: ['#5df2c8', '#2fb8ff', '#7a7bff'],
  mono: ['#eef2fb', '#b9c4d8', '#8a96ad'],
};
const STATUS_TEXT = { wartet: 'Wartet', laeuft: 'Läuft', fertig: 'Fertig', fehler: 'Fehler', abgebrochen: 'Abgebrochen' };

// ───────────────────────────── Server ─────────────────────────────
async function api(path, { body, raw } = {}) {
  const headers = { 'X-Factory-Token': BOOT.token };
  const init = { headers };
  if (raw) {
    Object.assign(init, { method: 'POST', body: raw });
    headers['Content-Type'] = 'application/octet-stream';
  } else if (body !== undefined) {
    Object.assign(init, { method: 'POST', body: JSON.stringify(body) });
    headers['Content-Type'] = 'application/json';
  }
  let res;
  try {
    res = await fetch(path, init);
  } catch {
    throw new Error('Keine Verbindung zur App – läuft sie noch?');
  }
  let data = {};
  try { data = await res.json(); } catch { /* leere Antwort */ }
  if (!res.ok) throw new Error(data.error || `Fehler ${res.status}`);
  return data;
}

// ───────────────────────────── Kleine Helfer ─────────────────────────────
function toast(message, kind = 'ok') {
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.innerHTML = `${icon(kind === 'bad' ? 'i-alert' : 'i-check')}<span>${esc(message)}</span>`;
  $('#toasts').append(el);
  setTimeout(() => { el.classList.add('out'); setTimeout(() => el.remove(), 320); }, kind === 'bad' ? 5200 : 2400);
}

async function copyText(text, label = 'Kopiert') {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const ta = Object.assign(document.createElement('textarea'), { value: text });
    ta.style.cssText = 'position:fixed;opacity:0';
    document.body.append(ta);
    ta.select();
    document.execCommand('copy');
    ta.remove();
  }
  toast(label);
}

const fmtDur = (s) => (s ? `${Math.round(s)} s` : '–');
function fmtDate(iso, withTime = true) {
  const d = new Date(iso);
  if (!iso || Number.isNaN(d.getTime())) return iso || '';
  const day = d.toLocaleDateString('de-DE', { day: '2-digit', month: '2-digit', year: 'numeric' });
  return withTime ? `${day}, ${d.toLocaleTimeString('de-DE', { hour: '2-digit', minute: '2-digit' })} Uhr` : day;
}
function hashHue(key) {
  let h = 0;
  for (const c of key) h = (h * 31 + c.charCodeAt(0)) % 360;
  return `hsl(${h} 70% 62%)`;
}
function nicheUi(key) {
  const niche = S.data.niches.find((n) => n.key === key) || { name: key, themenfelder: [] };
  const ui = NICHE_UI[key] || {};
  return {
    key,
    name: niche.name,
    label: ui.label || niche.name,
    hue: ui.hue || hashHue(key),
    icon: document.getElementById(`n-${key}`) ? `n-${key}` : 'i-studio',
    sub: (niche.themenfelder || []).slice(0, 3).join(' · ') || niche.tonalitaet || '',
  };
}
const evergreen = () => S.data.niches.filter((n) => n.gruppe === 'evergreen');
const openTrends = () => S.data.trends.ideen.filter((i) => i.offen);
const busyJobs = () => S.jobs.filter((j) => j.status === 'wartet' || j.status === 'laeuft');

// Umschalter mit gleitender Linse
function initSeg(el, value, onChange) {
  const thumb = $('.seg-thumb', el);
  const place = (animate = true) => {
    const btn = $('button.is-active', el);
    if (!btn || !btn.offsetWidth) return;
    if (!animate) thumb.style.transition = 'none';
    thumb.style.setProperty('--x', `${btn.offsetLeft}px`);
    thumb.style.setProperty('--w', `${btn.offsetWidth}px`);
    if (!animate) { void thumb.offsetWidth; thumb.style.transition = ''; }
  };
  const set = (v, animate = true) => {
    $$('button[data-value]', el).forEach((b) => b.classList.toggle('is-active', b.dataset.value === v));
    place(animate);
  };
  el.addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-value]');
    if (!btn || btn.classList.contains('is-active')) return;
    set(btn.dataset.value);
    onChange(btn.dataset.value);
  });
  el._place = place;
  el._set = set;
  set(value, false);
}
const placeSegs = () => $$('.seg').forEach((el) => el._place?.(false));

// ───────────────────────────── Lichtbrechung ─────────────────────────────
// An den Rändern der Kapseln wird der Hintergrund wie durch dickes Glas gebogen. Dafür braucht es
// SVG-Filter im backdrop-filter – das können nur Chromium-Engines (WebView2, Qt). In WebKit (macOS)
// bleibt es beim normalen Milchglas.
const CAN_LENS = /Chrome\//.test(navigator.userAgent);
let lensCount = 0;

function lensMap(w, h, r, bezel) {
  const canvas = Object.assign(document.createElement('canvas'), { width: w, height: h });
  const ctx = canvas.getContext('2d');
  const img = ctx.createImageData(w, h);
  for (let y = 0; y < h; y += 1) {
    for (let x = 0; x < w; x += 1) {
      const cx = x + 0.5 - w / 2;
      const cy = y + 0.5 - h / 2;
      const px = Math.abs(cx) - (w / 2 - r);
      const py = Math.abs(cy) - (h / 2 - r);
      const ox = Math.max(px, 0);
      const oy = Math.max(py, 0);
      const inside = -(Math.hypot(ox, oy) + Math.min(Math.max(px, py), 0) - r);   // Abstand vom Rand nach innen
      let dx = 0;
      let dy = 0;
      if (inside >= 0 && inside < bezel) {
        const m = (1 - inside / bezel) ** 2;
        if (px > 0 && py > 0) {
          const len = Math.hypot(ox, oy) || 1;
          dx = -Math.sign(cx) * (ox / len) * m;
          dy = -Math.sign(cy) * (oy / len) * m;
        } else if (px > py) {
          dx = -Math.sign(cx) * m;
        } else {
          dy = -Math.sign(cy) * m;
        }
      }
      const i = (y * w + x) * 4;
      img.data[i] = 128 + dx * 127;
      img.data[i + 1] = 128 + dy * 127;
      img.data[i + 2] = 128;
      img.data[i + 3] = 255;
    }
  }
  ctx.putImageData(img, 0, 0);
  return canvas.toDataURL();
}

function applyLens(el, { bezel = 13, scale = 26, blur = 7 } = {}) {
  const w = Math.round(el.offsetWidth);
  const h = Math.round(el.offsetHeight);
  if (!CAN_LENS || !w || !h || el._lens === `${w}x${h}`) return;
  el._lens = `${w}x${h}`;
  const radius = Math.min(parseFloat(getComputedStyle(el).borderTopLeftRadius) || 0, h / 2, w / 2);
  if (!el._lensId) { lensCount += 1; el._lensId = `lens-${lensCount}`; }
  let filter = document.getElementById(el._lensId);
  if (!filter) {
    filter = document.createElementNS('http://www.w3.org/2000/svg', 'filter');
    filter.id = el._lensId;
    filter.setAttribute('filterUnits', 'userSpaceOnUse');
    filter.setAttribute('primitiveUnits', 'userSpaceOnUse');
    filter.setAttribute('color-interpolation-filters', 'sRGB');
    $('.defs defs').append(filter);
  }
  filter.setAttribute('x', 0);
  filter.setAttribute('y', 0);
  filter.setAttribute('width', w);
  filter.setAttribute('height', h);
  filter.innerHTML = `<feImage href="${lensMap(w, h, radius, Math.min(bezel, h / 2))}" x="0" y="0" width="${w}" height="${h}" result="map" preserveAspectRatio="none"/>
    <feDisplacementMap in="SourceGraphic" in2="map" scale="${scale}" xChannelSelector="R" yChannelSelector="G"/>`;
  el.style.backdropFilter = `blur(${blur}px) url(#${el._lensId}) saturate(185%) brightness(1.06)`;
}

function watchLenses() {
  if (!CAN_LENS || typeof ResizeObserver === 'undefined') return;
  const big = { bezel: 20, scale: 34, blur: 10 };
  const observer = new ResizeObserver((entries) => {
    entries.forEach(({ target }) => applyLens(target, target.classList.contains('ccard') ? big : {}));
  });
  $$('.capsule, .ccard').forEach((el) => observer.observe(el));
}

// ───────────────────────────── Fenster (pywebview) ─────────────────────────────
const bridge = new Promise((resolve) => {
  if (BOOT.shell.mode !== 'desktop') return resolve(null);
  if (window.pywebview?.api) return resolve(window.pywebview.api);
  window.addEventListener('pywebviewready', () => resolve(window.pywebview.api), { once: true });
  setTimeout(() => resolve(window.pywebview?.api || null), 4000);
});
async function win(name, ...args) {
  const apiObj = await bridge;
  try { return (await apiObj?.[name]?.(...args)) ?? null; } catch (err) { console.warn(err); return null; }
}

async function closeWindow() {
  if (busyJobs().length && !(await confirmBox('Es läuft noch eine Produktion. Trotzdem beenden?', 'Beenden'))) return;
  win('close');
}

function confirmBox(text, okLabel) {
  return new Promise((resolve) => {
    const sheet = $('#sheet');
    sheet.innerHTML = `<div class="sheet-body" style="grid-column:1/-1;padding:6px"><h2>${esc(text)}</h2>
      <div class="sheet-foot"><button class="btn" data-answer="0">Abbrechen</button><button class="btn btn-danger" data-answer="1">${esc(okLabel)}</button></div></div>`;
    sheet.style.cssText = 'inset:auto;left:50%;top:38%;transform:translateX(-50%);width:min(460px,90%);display:block';
    sheet.hidden = false;
    $('#scrim').hidden = false;
    sheet.onclick = (e) => {
      const btn = e.target.closest('[data-answer]');
      if (!btn) return;
      sheet.onclick = null;
      closeSheet();
      resolve(btn.dataset.answer === '1');
    };
  });
}

// ───────────────────────────── Darstellung ─────────────────────────────
function applyPrefs() {
  const p = S.data.prefs;
  const backdrop = BOOT.shell.backdrop;
  const g = p.glass / 100;
  html.dataset.theme = p.theme === 'light' ? 'light' : 'dark';
  html.dataset.motion = p.motion ? '1' : '0';
  let tint = 1;
  let aurora = 0.5 + g * 0.5;
  if (backdrop === 'clear') { tint = 0.96 - g * 0.4; aurora = 0.34 + g * 0.3; }
  if (backdrop === 'acrylic') { tint = 0.72 - g * 0.45; aurora = 0.22 + g * 0.28; }
  if (backdrop === 'vibrancy') { tint = 0.62 - g * 0.5; aurora = 0.2 + g * 0.26; }
  html.style.setProperty('--tint', tint.toFixed(3));
  html.style.setProperty('--aurora', aurora.toFixed(3));
  const [a1, a2, a3] = ACCENTS[p.accent] || ACCENTS.aurora;
  html.style.setProperty('--a1', a1);
  html.style.setProperty('--a2', a2);
  html.style.setProperty('--a3', a3);
}
// Vom Fenster aufgerufen, falls die Windows-Unschärfe nicht verfügbar ist
window.setBackdrop = (name) => { BOOT.shell.backdrop = name; html.dataset.backdrop = name; if (S.data) applyPrefs(); };
let prefsTimer = null;
function setPref(key, value) {
  S.data.prefs[key] = value;
  applyPrefs();
  clearTimeout(prefsTimer);
  prefsTimer = setTimeout(() => api('/api/prefs', { body: S.data.prefs }).catch((e) => toast(e.message, 'bad')), 350);
}

// ───────────────────────────── Studio ─────────────────────────────
function renderStudio() {
  const lim = S.data.limits;
  $('#view-studio').innerHTML = `
    <div class="studio">
      <div class="composer glass">
        <header class="composer-head">
          <div><h1>Neues Video</h1><p class="sub">${lim.min_s}–${lim.max_s} Sekunden · 9:16 · Untertitel, B-Roll und Musik inklusive</p></div>
          <div class="seg" id="seg-mode"><span class="seg-thumb"></span>
            <button data-value="niche">Nische</button><button data-value="topic">Thema</button>
            <button data-value="trend">Trend</button><button data-value="script">Eigenes Skript</button></div>
        </header>
        <div class="composer-body" id="mode-body"></div>
        <div class="options" id="options"></div>
        <footer class="cta">
          <div class="ready" id="ready"></div>
          <div class="cta-msg" id="cta-msg"></div>
          <button class="btn-primary" id="btn-create"></button>
        </footer>
      </div>
      <aside class="stage glass" id="stage"></aside>
    </div>`;
  initSeg($('#seg-mode'), S.form.mode, (mode) => {
    S.form.mode = mode;
    renderModeBody();
    renderOptions();
    updateCta();
  });
  $('#btn-create').addEventListener('click', submit);
  bindModeBody($('#mode-body'));
  bindStage($('#stage'));
  renderModeBody();
  renderOptions();
  updateCta();
  S.stageKey = null;
  renderStage();
}

const stepper = () => `<div class="stepper"><span>Anzahl</span>
  <button data-step="-1" aria-label="weniger">${icon('i-minus')}</button><b>${S.form.count}</b>
  <button data-step="1" aria-label="mehr">${icon('i-plus')}</button></div>`;

function styleChips() {
  return `<div class="label">Stil der Nische</div><div class="chips">${evergreen().map((n) => {
    const u = nicheUi(n.key);
    return `<button class="chip ${S.form.niche === n.key ? 'is-active' : ''}" data-niche="${esc(n.key)}" style="--hue:${u.hue}">${icon(u.icon)}${esc(u.label)}</button>`;
  }).join('')}</div>`;
}

function nicheInfo() {
  const n = S.data.niches.find((x) => x.key === S.form.niche);
  if (!n) return '';
  const voice = (S.form.lang === 'en' ? n.stimme_en : n.stimme).replace(/^[a-z]{2}-[A-Z]{2}-/, '').replace(/(Multilingual)?Neural$/, '');
  return `<div><small>Tonalität</small><b title="${esc(n.tonalitaet)}">${esc(n.tonalitaet)}</b></div>
    <div><small>Stimme</small><b>${esc(voice)}</b></div><div><small>Musik</small><b>${esc(n.musik_stimmung)}</b></div>`;
}

function renderModeBody() {
  const f = S.form;
  const body = $('#mode-body');
  if (!body) return;
  if (!evergreen().some((n) => n.key === f.niche)) f.niche = evergreen()[0]?.key || S.data.default_niche;   // Nische wurde entfernt
  body.classList.toggle('is-trend', f.mode === 'trend');
  if (f.mode === 'niche') {
    body.innerHTML = `<div class="tiles">${evergreen().map((n) => {
      const u = nicheUi(n.key);
      return `<button class="tile ${f.niche === n.key ? 'is-active' : ''}" data-niche="${esc(n.key)}" style="--hue:${u.hue}">
        <span class="orb">${icon(u.icon)}</span><span class="tick">${icon('i-check')}</span>
        <b>${esc(u.label)}</b><small>${esc(u.sub)}</small></button>`;
    }).join('')}</div>
    <div class="ninfo" id="ninfo">${nicheInfo()}</div>
    <div class="row between belowtiles"><p class="hint">Claude schlägt neue Themen vor. Was schon produziert wurde, kommt nicht noch einmal.</p>${stepper()}</div>`;
  } else if (f.mode === 'topic') {
    const examples = ['Warum wir Träume sofort vergessen', 'Warum Oktopusse drei Herzen haben', 'Wie Rabatte dein Gehirn austricksen'];
    body.innerHTML = `<label class="field"><textarea id="topic" rows="3" maxlength="240" placeholder="Worum soll es gehen?">${esc(f.topic)}</textarea></label>
      <div class="chips examples">${examples.map((t) => `<button class="chip" data-example="${esc(t)}">${esc(t)}</button>`).join('')}</div>
      ${styleChips()}`;
  } else if (f.mode === 'trend') {
    const t = S.data.trends;
    const ideas = openTrends();
    body.innerHTML = `<div class="row between"><p class="hint">${t.recherchiert ? `Recherchiert am ${esc(fmtDate(t.recherchiert))}` : 'Noch keine Trend-Recherche'}
        ${t.veraltet ? `<span class="badge warn">älter als ${t.max_alter_h} h</span>` : '<span class="badge ok">aktuell</span>'}</p>
        <button class="btn btn-small" data-goto="trends">${icon('i-trend')}Alle Trends</button></div>
      <div class="trendlist">${ideas.map((i) => `<button class="trow ${f.trendNumbers.includes(i.nr) ? 'is-active' : ''}" data-trend="${i.nr}">
          <span class="num">${i.nr}</span><span><b>${esc(i.thema)}</b><small>${esc(i.warum_jetzt)}</small></span>
          <span class="badge">${esc(nicheUi(i.nische).label)}</span></button>`).join('') || '<p class="hint">Keine offenen Ideen – unter „Trends“ neu recherchieren.</p>'}</div>
      <div class="row between"><p class="hint">${f.trendNumbers.length ? `${plural(f.trendNumbers.length, 'Idee', 'Ideen')} ausgewählt.` : 'Nichts ausgewählt: Es werden die obersten offenen Ideen genommen.'}</p>${f.trendNumbers.length ? '' : stepper()}</div>`;
  } else {
    const info = f.scriptInfo;
    const voice = f.voiceUpload;
    body.innerHTML = `<div class="drops">
        <label class="drop ${info ? 'is-set' : ''}" data-drop="script">
          <input type="file" accept=".json,application/json" hidden>
          <span class="orb">${icon(info ? 'i-check' : 'i-doc')}</span>
          ${info ? `<b>${esc(info.titel)}</b><small>${info.words} Wörter · ${info.scenes} Szenen · ${esc(info.name)}</small>
                    <button class="icon-btn clear" data-clear="script" aria-label="Entfernen">${icon('i-close')}</button>`
                 : '<b>Skript (.json)</b><small>Datei hierher ziehen oder klicken. Felder: hook, szenen, hashtags, quellen</small>'}
        </label>
        <label class="drop ${voice ? 'is-set' : ''}" data-drop="voice">
          <input type="file" accept="audio/*,.mp3,.wav,.m4a,.ogg,.flac" hidden>
          <span class="orb">${icon(voice ? 'i-check' : 'i-mic')}</span>
          ${voice ? `<b>${esc(voice.name)}</b><small>${voice.dauer_s} s · eigene Aufnahme</small>
                     <button class="icon-btn clear" data-clear="voice" aria-label="Entfernen">${icon('i-close')}</button>`
                  : `<b>Eigene Aufnahme (optional)</b><small>mp3, wav, m4a · ${S.data.limits.min_s}–${S.data.limits.max_s} Sekunden. Ohne Aufnahme spricht die KI-Stimme.</small>`}
        </label>
      </div>${styleChips()}`;
  }
}

function bindModeBody(body) {
  body.addEventListener('click', (e) => {
    const f = S.form;
    const pick = (sel) => e.target.closest(sel);
    let el;
    if ((el = pick('[data-clear]'))) {
      e.preventDefault();
      if (el.dataset.clear === 'script') { f.script = null; f.scriptInfo = null; } else { f.voiceUpload = null; }
      renderModeBody(); renderOptions(); updateCta();
    } else if ((el = pick('[data-niche]'))) {
      f.niche = el.dataset.niche;
      $$('[data-niche]', body).forEach((b) => b.classList.toggle('is-active', b.dataset.niche === f.niche));
      if ($('#ninfo')) $('#ninfo').innerHTML = nicheInfo();
    } else if ((el = pick('[data-step]'))) {
      f.count = Math.max(1, Math.min(10, f.count + Number(el.dataset.step)));
      $$('.stepper b', body).forEach((b) => { b.textContent = f.count; });
      updateCta();
    } else if ((el = pick('[data-example]'))) {
      f.topic = el.dataset.example;
      $('#topic').value = f.topic;
      updateCta();
    } else if ((el = pick('[data-trend]'))) {
      const nr = Number(el.dataset.trend);
      f.trendNumbers = f.trendNumbers.includes(nr) ? f.trendNumbers.filter((n) => n !== nr) : [...f.trendNumbers, nr];
      renderModeBody(); updateCta();
    }
  });
  body.addEventListener('input', (e) => {
    if (e.target.id === 'topic') { S.form.topic = e.target.value; updateCta(); }
  });
  body.addEventListener('keydown', (e) => {
    if (e.target.id === 'topic' && e.key === 'Enter' && (e.metaKey || e.ctrlKey)) submit();
  });
  body.addEventListener('change', (e) => {
    const drop = e.target.closest('[data-drop]');
    const file = e.target.files?.[0];
    if (drop && file) takeFile(drop.dataset.drop, file);
  });
  body.addEventListener('dragover', (e) => {
    const drop = e.target.closest('[data-drop]');
    if (drop) { e.preventDefault(); drop.classList.add('is-over'); }
  });
  body.addEventListener('dragleave', (e) => e.target.closest('[data-drop]')?.classList.remove('is-over'));
  body.addEventListener('drop', (e) => {
    const drop = e.target.closest('[data-drop]');
    const file = e.dataTransfer?.files?.[0];
    if (drop && file) { e.preventDefault(); takeFile(drop.dataset.drop, file); }
  });
}

async function takeFile(kind, file) {
  try {
    if (kind === 'script') {
      const data = JSON.parse(await file.text());
      if (!data || !data.hook || !Array.isArray(data.szenen) || !data.szenen.length) throw new Error('Das Skript braucht mindestens „hook“ und „szenen“.');
      const text = [data.hook, ...data.szenen.map((s) => (typeof s === 'string' ? s : s.text || ''))].join(' ');
      S.form.script = data;
      S.form.scriptInfo = { name: file.name, titel: data.titel || data.hook, scenes: data.szenen.length,
                            words: text.split(/\s+/).filter((w) => /[\p{L}\p{N}]/u.test(w)).length };
    } else {
      S.form.voiceUpload = await api(`/api/upload?name=${encodeURIComponent(file.name)}`, { raw: file });
      toast(`Aufnahme geladen (${S.form.voiceUpload.dauer_s} s)`);
    }
  } catch (err) {
    toast(err instanceof SyntaxError ? 'Die Datei ist kein gültiges JSON.' : err.message, 'bad');
  }
  renderModeBody(); renderOptions(); updateCta();
}

function renderOptions() {
  const f = S.form;
  const voices = S.data.voices[f.lang] || [];
  const ownVoice = f.mode === 'script' && f.voiceUpload;
  $('#options').innerHTML = `
    <div class="seg" id="seg-lang"><span class="seg-thumb"></span><button data-value="de">Deutsch</button><button data-value="en">English</button></div>
    ${ownVoice ? `<span class="chip static">${icon('i-mic')}Eigene Aufnahme</span>` : `<label class="selectwrap">${icon('i-mic')}
      <select id="voice" aria-label="Stimme"><option value="">Stimme der Nische</option>
        ${voices.map((v) => `<option value="${esc(v.id)}" ${f.voice === v.id ? 'selected' : ''}>${esc(v.label)}</option>`).join('')}
        ${S.data.system.keys.elevenlabs ? `<option value="elevenlabs" ${f.voice === 'elevenlabs' ? 'selected' : ''}>ElevenLabs</option>` : ''}
      </select></label>`}
    <button class="toggle" role="switch" id="opt-music" aria-checked="${f.music}"><i class="switch"></i>${icon('i-music')}Musik</button>
    ${f.mode === 'script' ? '' : `<button class="toggle" role="switch" id="opt-script" aria-checked="${f.scriptOnly}" title="Nur das Skript schreiben – zum Selbst-Einsprechen"><i class="switch"></i>${icon('i-doc')}Nur Skript</button>`}`;
  initSeg($('#seg-lang'), f.lang, (lang) => {
    f.lang = lang;
    f.voice = '';
    renderOptions();
    if ($('#ninfo')) $('#ninfo').innerHTML = nicheInfo();
  });
  $('#voice')?.addEventListener('change', (e) => { f.voice = e.target.value; });
  $('#opt-music').addEventListener('click', () => { f.music = !f.music; renderOptions(); });
  $('#opt-script')?.addEventListener('click', () => { f.scriptOnly = !f.scriptOnly; renderOptions(); updateCta(); });
}

function updateCta() {
  const f = S.form;
  const sys = S.data.system;
  const scriptOnly = f.scriptOnly && f.mode !== 'script';
  const chips = [];
  if (f.mode !== 'script') chips.push(['Claude', sys.keys.anthropic ? '' : 'bad', sys.keys.anthropic ? 'Schlüssel vorhanden' : 'ANTHROPIC_API_KEY fehlt']);
  if (!scriptOnly) {
    if (f.mode === 'script' && f.voiceUpload) chips.push(['Aufnahme', '', 'eigene Stimme']);
    else chips.push(['Stimme', sys.voice_ready ? '' : 'bad', sys.voice_ready ? sys.tts_provider : `Schlüssel für ${sys.tts_provider} fehlt`]);
    const stock = [sys.keys.pexels && 'Pexels', sys.keys.pixabay && 'Pixabay'].filter(Boolean).join(' + ');
    chips.push(['B-Roll', stock ? '' : 'warn', stock || 'ohne Pixabay- oder Pexels-Schlüssel nur Farbflächen']);
    if (!sys.ffmpeg.ok) chips.push(['ffmpeg', 'bad', 'ffmpeg fehlt']);
  }
  $('#ready').innerHTML = chips.map(([label, state, tip]) => `<button class="chip" data-goto="settings" title="${esc(tip)}"><i class="dot ${state}"></i>${label}</button>`).join('');

  const n = f.mode === 'niche' ? f.count : f.mode === 'trend' ? (f.trendNumbers.length || f.count) : 1;
  let label = n > 1 ? `${n} Videos erzeugen` : 'Video erzeugen';
  if (scriptOnly) label = n > 1 ? `${n} Skripte schreiben` : 'Skript schreiben';
  let hint = '';
  if (f.mode === 'topic' && f.topic.trim().length < 4) hint = 'Gib oben ein Thema ein.';
  if (f.mode === 'script' && !f.script) hint = 'Wähle zuerst eine Skriptdatei.';
  if (f.mode === 'trend' && !openTrends().length) hint = 'Keine offenen Trend-Ideen.';
  const btn = $('#btn-create');
  btn.innerHTML = `${icon('i-play', 'solid')}<span>${label}</span>`;
  btn.disabled = Boolean(hint);
  ctaMessage(hint, false);
}
function ctaMessage(text, bad) {
  const el = $('#cta-msg');
  el.textContent = text;
  el.classList.toggle('bad', Boolean(bad));
}

async function submit() {
  const f = S.form;
  const btn = $('#btn-create');
  if (btn.disabled) return;
  const body = { mode: f.mode, lang: f.lang, music: f.music, voice: f.voice || null, script_only: f.scriptOnly, whisper: f.whisper };
  if (f.mode === 'niche') Object.assign(body, { niche: f.niche, count: f.count });
  if (f.mode === 'topic') Object.assign(body, { topic: f.topic.trim(), niche: f.niche });
  if (f.mode === 'trend') Object.assign(body, f.trendNumbers.length ? { trend_numbers: f.trendNumbers } : { count: f.count });
  if (f.mode === 'script') Object.assign(body, { script: f.script, niche: f.niche, voice_upload: f.voiceUpload?.id || null });
  btn.classList.add('is-busy');
  try {
    const res = await api('/api/jobs', { body });
    S.focus = res.ids[0];
    f.trendNumbers = [];
    if (f.mode === 'trend') renderModeBody();
    updateCta();
    toast(res.ids.length > 1 ? `${res.ids.length} Aufträge gestartet` : 'Gestartet');
    await poll();
  } catch (err) {
    ctaMessage(err.message, true);
  } finally {
    btn.classList.remove('is-busy');
  }
}

// ───────────────────────────── Bühne (Handy) ─────────────────────────────
const DEMO = [['DEIN', 'GEHIRN', 'LÖSCHT'], ['TRÄUME', 'SOFORT'], ['ABER', 'WARUM?'], ['DAS', 'STECKT'], ['DAHINTER']];
let demoTimer = null;
function startDemo() {
  clearInterval(demoTimer);
  let g = 0;
  let w = 0;
  const step = () => {
    const cap = $('#demo-cap');
    if (!cap) return clearInterval(demoTimer);
    cap.innerHTML = DEMO[g].map((t, i) => `<b class="${i === w ? 'on' : ''}">${t}</b>`).join(' ');
    if (w === 0) { cap.classList.remove('pop'); void cap.offsetWidth; cap.classList.add('pop'); }
    w += 1;
    if (w >= DEMO[g].length) { w = 0; g = (g + 1) % DEMO.length; }
    return null;
  };
  step();
  if (S.data.prefs.motion) demoTimer = setInterval(step, 540);
}

function focusJob() {
  if (!S.jobs.length) return null;
  return S.jobs.find((j) => j.id === S.focus) || S.jobs.find((j) => j.status === 'laeuft') || S.jobs[S.jobs.length - 1];
}
const stageName = (job) => job.stages.find((s) => s.key === job.stage)?.label || '';
function metaLine(job) {
  const parts = [nicheUi(job.niche).label];
  if (job.kind === 'skript') parts.push('nur Skript');
  if (job.status === 'laeuft' && job.started) parts.push(`seit ${Math.max(1, Math.round((Date.now() / 1000 - job.started) / 60))} min`);
  if (job.status !== 'laeuft') parts.push(STATUS_TEXT[job.status]);
  return parts.join(' · ');
}

function stageHtml(job) {
  let screen = '';
  let below = '';
  if (!job) {
    screen = `<div class="demo"><div class="demo-bg"><i></i><i></i><i></i></div>
      <div class="demo-hook"><span>DEIN THEMA.</span><span class="acc">DEIN VIDEO.</span></div>
      <div class="demo-cap" id="demo-cap"></div><div class="demo-note">Vorschau des Untertitel-Stils</div></div>`;
    below = `<div class="stage-title">Bereit für dein erstes Video</div>
      <div class="stage-meta">Glas-Karte für den Hook, Untertitel mit leuchtendem Wort – genau so wird es gerendert.</div>`;
  } else if (job.status === 'wartet' || job.status === 'laeuft') {
    screen = `<div class="run"><div class="ringwrap">
        <svg class="ring" viewBox="0 0 120 120"><circle class="ring-bg" cx="60" cy="60" r="52"/><circle class="ring-fg" cx="60" cy="60" r="52" pathLength="100"/></svg>
        <div class="ring-label"><b><span id="pct">0</span><small>%</small></b></div></div>
      <div class="run-stage" id="run-stage"></div><div class="run-detail" id="run-detail"></div></div>`;
    below = `<div class="stage-title">${esc(job.title)}</div><div class="stage-meta" id="stage-meta"></div>
      <div class="steps" id="steps"></div>
      <div class="stage-actions"><button class="btn btn-small btn-danger" data-cancel="${job.id}">${icon('i-stop')}Abbrechen</button></div>`;
  } else if (job.status === 'fertig' && job.kind === 'video' && job.output) {
    screen = `<video controls playsinline loop preload="metadata" poster="${media(job.output, 'cover.jpg')}" src="${media(job.output, 'video.mp4')}"></video>`;
    below = `<div class="stage-title">${esc(job.title)}</div><div class="stage-meta">${esc(metaLine(job))}</div>
      <div class="stage-actions">
        <button class="btn btn-small" data-detail="${esc(job.output)}">${icon('i-eye')}Details</button>
        <button class="btn btn-small" data-copy-desc="${esc(job.output)}">${icon('i-copy')}Beschreibung</button>
        <button class="btn btn-small" data-open="${esc(job.output)}">${icon('i-folder')}Ordner</button></div>
      <div class="kilabel">${icon('i-alert')}Beim Upload „KI-generierte Inhalte“ einschalten</div>`;
  } else if (job.status === 'fertig') {
    const trends = job.kind === 'trends' || job.kind === 'nischen';
    const [head, text] = job.kind === 'trends' ? ['Trends aktualisiert', 'neue Ideen mit Quelle und Datum']
      : job.kind === 'nischen' ? ['Neue Nischen gefunden', 'Vorschläge stehen unter „Trends“']
        : ['Skript fertig', 'Sprechertext liegt im Ausgabeordner'];
    screen = `<div class="run"><span class="orb" style="--hue:var(--ok)">${icon('i-check')}</span>
      <div class="run-stage">${head}</div>
      <div class="run-detail">${text}</div></div>`;
    below = `<div class="stage-title">${esc(job.title)}</div><div class="stage-meta">${esc(metaLine(job))}</div>
      <div class="stage-actions">${trends ? `<button class="btn btn-small" data-goto="trends">${icon('i-trend')}Trends ansehen</button>`
        : `<button class="btn btn-small" data-detail="${esc(job.output)}">${icon('i-eye')}Sprechertext</button>
           <button class="btn btn-small" data-open="${esc(job.output)}">${icon('i-folder')}Ordner</button>`}</div>`;
  } else {
    const cancelled = job.status === 'abgebrochen';
    screen = `<div class="run ${cancelled ? '' : 'bad'}"><span class="orb" style="--hue:${cancelled ? 'var(--text-3)' : 'var(--bad)'}">${icon(cancelled ? 'i-stop' : 'i-alert')}</span>
      <div class="run-stage">${cancelled ? 'Abgebrochen' : 'Fehlgeschlagen'}</div>
      <div class="run-msg selectable">${esc(job.error)}</div></div>`;
    below = `<div class="stage-title">${esc(job.title)}</div><div class="stage-meta">${esc(metaLine(job))}</div>
      <div class="stage-actions"><button class="btn btn-small" data-log>${icon('i-log')}Protokoll</button>
        ${/Schlüssel|Key/i.test(job.error) ? `<button class="btn btn-small" data-goto="settings">${icon('i-key')}Einstellungen</button>` : ''}</div>`;
  }
  return `<div class="phone"><div class="screen">${screen}</div></div><div class="stage-info">${below}<div class="queue" id="queue"></div></div>`;
}

function renderStage() {
  const el = $('#stage');
  if (!el) return;
  const job = focusJob();
  const key = job ? `${job.id}:${job.status}:${job.output || ''}` : 'idle';
  if (key !== S.stageKey) {
    S.stageKey = key;
    el.innerHTML = stageHtml(job);
    if (!job) startDemo();
  }
  if (job && (job.status === 'laeuft' || job.status === 'wartet')) {
    const pct = Math.round(job.percent);
    $('.ring-fg', el).style.strokeDasharray = `${Math.max(job.percent, 0.5)} 100`;
    $('#pct', el).textContent = pct;
    $('#run-stage', el).textContent = job.status === 'wartet' ? 'In der Warteschlange' : stageName(job) || 'Startet …';
    $('#run-detail', el).textContent = job.status === 'wartet' ? 'beginnt, sobald der laufende Auftrag fertig ist' : job.detail;
    $('#stage-meta', el).textContent = metaLine(job);
    $('#steps', el).innerHTML = job.stages.map((s) => `<i class="${s.state}" title="${esc(s.label)}">${s.state === 'active' ? esc(s.label) : ''}</i>`).join('');
  }
  const queue = $('#queue', el);
  if (queue) {
    const rows = S.jobs.length > 1 ? [...S.jobs].reverse().slice(0, 12) : [];
    const current = job?.id;
    queue.innerHTML = rows.map((j) => {
      const dot = { laeuft: 'busy', fertig: '', fehler: 'bad', wartet: 'off', abgebrochen: 'off' }[j.status];
      return `<button class="qrow ${j.id === current ? 'is-active' : ''}" data-focus="${j.id}"><i class="dot ${dot}"></i><span>${esc(j.title)}</span>
        <em>${j.status === 'laeuft' ? `${Math.round(j.percent)} %` : STATUS_TEXT[j.status]}</em></button>`;
    }).join('');
  }
}

function bindStage(el) {
  el.addEventListener('click', async (e) => {
    const pick = (sel) => e.target.closest(sel);
    let b;
    if ((b = pick('[data-cancel]'))) {
      await api('/api/jobs/cancel', { body: { id: b.dataset.cancel } }).catch((err) => toast(err.message, 'bad'));
      poll();
    } else if ((b = pick('[data-focus]'))) {
      S.focus = b.dataset.focus;
      renderStage();
    } else if ((b = pick('[data-copy-desc]'))) {
      copyDescription(b.dataset.copyDesc);
    }
  });
}

async function copyDescription(folder) {
  try {
    const item = await api(`/api/library/item?folder=${encodeURIComponent(folder)}`);
    const script = item.meta?.skript || {};
    await copyText(`${script.beschreibung || ''}\n\n${(script.hashtags || []).join(' ')}`.trim(), 'Beschreibung und Hashtags kopiert');
  } catch (err) {
    toast(err.message, 'bad');
  }
}

function renderStatus() {
  const running = S.jobs.find((j) => j.status === 'laeuft');
  const waiting = S.jobs.filter((j) => j.status === 'wartet').length;
  const last = S.jobs[S.jobs.length - 1];
  let cls = 'dot';
  let text = 'Bereit';
  let pct = 0;
  if (S.offline) { cls = 'dot bad'; text = 'Keine Verbindung'; }
  else if (running) { cls = 'dot busy'; pct = running.percent; text = `${stageName(running) || 'Startet'} · ${Math.round(pct)} %${waiting ? ` · +${waiting}` : ''}`; }
  else if (waiting) { cls = 'dot busy'; text = `${waiting} in der Warteschlange`; }
  else if (last?.status === 'fehler') { cls = 'dot bad'; text = 'Fehlgeschlagen'; }
  else if (last?.status === 'fertig') { text = 'Fertig'; pct = 100; }
  $('#status .dot').className = cls;
  $('#status-text').textContent = text;
  const cs = $('#c-status');
  if (cs) { cs.textContent = running ? `${running.title} – ${text}` : text; $('#c-bar').style.width = `${running ? pct : 0}%`; }
}

// ───────────────────────────── Trends ─────────────────────────────
function renderTrends() {
  const t = S.data.trends;
  const busy = S.jobs.some((j) => j.kind === 'trends' && (j.status === 'wartet' || j.status === 'laeuft'));
  $('#view-trends').innerHTML = `<div class="page">
    <header class="page-head"><div><h1>Trends</h1>
      <p class="sub">${t.recherchiert ? `Recherchiert am ${esc(fmtDate(t.recherchiert))}` : 'Noch keine Recherche'}
        ${t.veraltet ? `<span class="badge warn">älter als ${t.max_alter_h} h</span>` : '<span class="badge ok">aktuell</span>'}
        · ohne Tragödien, Unglücke und politische Polarisierung</p></div><span class="spacer"></span>
      <button class="btn" id="trends-refresh" ${busy ? 'disabled' : ''}>${icon('i-refresh')}${busy ? 'Recherche läuft …' : 'Neu recherchieren'}</button></header>
    ${t.ideen.length ? `<div class="tgrid">${t.ideen.map((i) => {
      const u = nicheUi(i.nische);
      const source = i.quelle_url ? `<a href="${esc(i.quelle_url)}" target="_blank" rel="noopener noreferrer">${icon('i-link')}${esc(i.quelle_name || 'Quelle')}</a>` : `<span>${esc(i.quelle_name)}</span>`;
      return `<article class="tcard glass ${i.offen ? '' : 'is-done'}">
        <header><span class="tnum">${i.nr}</span><span class="chip static is-active" style="--hue:${u.hue}">${icon(u.icon)}${esc(u.label)}</span><span class="spacer"></span>
          ${i.offen ? '' : '<span class="badge ok">produziert</span>'}</header>
        <h3>${esc(i.thema)}</h3><p>${esc(i.warum_jetzt)}</p>
        <footer>${source}<span>${esc(i.datum)}</span><span class="spacer"></span>
          <button class="btn-primary small" data-produce="${i.nr}">${icon('i-play', 'solid')}Produzieren</button></footer></article>`;
    }).join('')}</div>` : `<div class="empty glass"><span class="orb">${icon('i-trend')}</span><b>Noch keine Trend-Ideen</b><span>„Neu recherchieren“ sucht, was in Deutschland gerade Aufmerksamkeit bekommt.</span></div>`}
    ${nicheIdeasHtml()}
  </div>`;
}

// Vorschläge für neue Nischen (Recherche per Claude) – ein Klick übernimmt sie ins Studio
function nicheIdeasHtml() {
  const ideas = S.data.niche_ideas;
  const busy = S.jobs.some((j) => j.kind === 'nischen' && (j.status === 'wartet' || j.status === 'laeuft'));
  const own = S.data.niches.filter((n) => n.eigene);
  return `<header class="page-head" style="margin-top:22px"><div><h1>Neue Nischen</h1>
      <p class="sub">${ideas.recherchiert ? `Recherchiert am ${esc(fmtDate(ideas.recherchiert))}` : 'Noch keine Recherche'}
        · Vorschläge, die es bei dir noch nicht gibt${own.length ? ` · ${plural(own.length, 'eigene Nische', 'eigene Nischen')} aktiv` : ''}</p></div><span class="spacer"></span>
      <button class="btn" id="niches-discover" ${busy ? 'disabled' : ''}>${icon('i-refresh')}${busy ? 'Suche läuft …' : 'Neue Nischen suchen'}</button></header>
    ${ideas.ideen.length ? `<div class="tgrid">${ideas.ideen.map((i) => {
      const source = i.quelle_url ? `<a href="${esc(i.quelle_url)}" target="_blank" rel="noopener noreferrer">${icon('i-link')}${esc(i.quelle_name || 'Quelle')}</a>` : `<span>${esc(i.quelle_name)}</span>`;
      return `<article class="tcard glass">
        <header><span class="orb" style="--hue:${hashHue(i.key)}">${icon('i-studio')}</span><h3>${esc(i.name)}</h3><span class="spacer"></span>
          ${i.uebernommen ? '<span class="badge ok">übernommen</span>' : ''}</header>
        <p>${esc(i.warum)}</p>
        <div class="chips">${(i.themenfelder || []).slice(0, 6).map((t) => `<span class="chip static">${esc(t)}</span>`).join('')}</div>
        <footer>${source}<span>${esc(i.musik_stimmung)} · ${esc(i.stimme)}</span><span class="spacer"></span>
          ${i.uebernommen ? `<button class="btn btn-small" data-niche-remove="${esc(i.key)}">Entfernen</button>`
            : `<button class="btn-primary small" data-niche-add="${esc(i.key)}">${icon('i-plus')}Übernehmen</button>`}</footer></article>`;
    }).join('')}</div>` : `<div class="empty glass"><span class="orb">${icon('i-studio')}</span><b>Noch keine Vorschläge</b>
      <span>„Neue Nischen suchen“ recherchiert, welche Wissens-Nischen auf TikTok in Deutschland gerade wachsen.</span></div>`}`;
}

async function nicheAction(path, key, okText) {
  try {
    const body = key ? { key } : {};
    const res = await api(path, { body });
    if (res.niches) Object.assign(S.data, res);
    if (res.id) { S.focus = res.id; await poll(); }
    renderTrends();
    renderModeBody();
    toast(okText);
  } catch (err) {
    toast(err.message, 'bad');
  }
}

async function checkService(btn) {
  btn.disabled = true;
  try {
    const res = await api('/api/check', { body: { service: btn.dataset.check } });
    toast(res.text, res.ok ? 'ok' : 'bad');
  } catch (err) {
    toast(err.message, 'bad');
  }
  btn.disabled = false;
}

async function produceTrend(nr) {
  try {
    const res = await api('/api/jobs', { body: { mode: 'trend', trend_numbers: [nr], lang: S.form.lang, music: S.form.music, whisper: S.form.whisper } });
    S.focus = res.ids[0];
    showView('studio');
    await poll();
  } catch (err) {
    toast(err.message, 'bad');
  }
}
async function refreshTrends() {
  try {
    const res = await api('/api/trends/refresh', { body: {} });
    S.focus = res.id;
    toast('Trend-Recherche gestartet');
    await poll();
    renderTrends();
  } catch (err) {
    toast(err.message, 'bad');
  }
}

// ───────────────────────────── Bibliothek ─────────────────────────────
function renderLibrary() {
  const items = S.data.library;
  $('#view-library').innerHTML = `<div class="page">
    <header class="page-head"><div><h1>Bibliothek</h1><p class="sub">${items.length ? `${plural(items.length, 'Eintrag', 'Einträge')} im Ausgabeordner` : 'Hier landen deine fertigen Videos.'}</p></div>
      <span class="spacer"></span><button class="btn" data-open="">${icon('i-folder')}Ausgabeordner</button></header>
    ${items.length ? `<div class="lgrid">${items.map((it) => (it.kind === 'video'
      ? `<button class="ltile" data-detail="${esc(it.folder)}">${it.cover ? `<img loading="lazy" alt="" src="${media(it.folder, 'cover.jpg')}">` : ''}
          <span class="top"><span class="pill">${icon('i-clock')}${fmtDur(it.dauer_s)}</span>${it.hinweise ? `<span class="pill warn" title="Hinweise prüfen">${icon('i-alert')}${it.hinweise}</span>` : ''}</span>
          <span class="cap"><b>${esc(it.titel)}</b><small>${esc(it.nische ? nicheUi(it.nische).label : '')}${it.erstellt ? ` · ${esc(fmtDate(it.erstellt, false))}` : ''}</small></span></button>`
      : `<button class="ltile is-script" data-detail="${esc(it.folder)}"><span class="orb" style="--hue:var(--a2)">${icon('i-doc')}</span>
          <span class="cap"><b>${esc(it.titel)}</b><small>Skript zum Einsprechen</small></span></button>`)).join('')}</div>`
      : `<div class="empty glass"><span class="orb">${icon('i-film')}</span><b>Noch nichts produziert</b><span>Starte im Studio – das fertige Video erscheint hier mit Cover, Beschreibung und Quellen.</span>
          <button class="btn" data-goto="studio">${icon('i-studio')}Zum Studio</button></div>`}
  </div>`;
}

function sheetVideo(item) {
  const m = item.meta;
  const script = m.skript || {};
  const checks = Object.fromEntries((m.quellen_pruefung || []).map((c) => [c.url, c]));
  const credits = {};
  for (const clip of m.clips || []) {
    const name = clip.author || (clip.source === 'lokal' ? 'Eigene Clips' : clip.source === 'generiert' ? 'Farbfläche (kein Clip gefunden)' : clip.source);
    credits[name] = (credits[name] || 0) + 1;
  }
  const voice = m.stimme?.anbieter === 'eigene-aufnahme' ? 'Eigene Aufnahme' : m.stimme?.stimme;
  const chips = [m.nische_name, `${fmtDur(m.dauer_s)}`, m.audio?.lufs != null ? `${m.audio.lufs} LUFS` : '', voice, m.audio?.musik ? `♪ ${m.audio.musik}` : 'ohne Musik'].filter(Boolean);
  return `<button class="icon-btn sheet-close" data-close aria-label="Schließen">${icon('i-close')}</button>
    <div class="sheet-media"><div class="phone"><div class="screen"><video controls playsinline loop preload="metadata" poster="${media(item.folder, 'cover.jpg')}" src="${media(item.folder, 'video.mp4')}"></video></div></div></div>
    <div class="sheet-body selectable">
      <h2>${esc(m.titel)}</h2>
      <div class="chips">${chips.map((c) => `<span class="chip static">${esc(c)}</span>`).join('')}</div>
      <section><h3>Beschreibung<button class="btn btn-small" data-copy="${esc(`${script.beschreibung || ''}\n\n${(script.hashtags || []).join(' ')}`.trim())}">${icon('i-copy')}Kopieren</button></h3>
        <div class="textbox">${esc(script.beschreibung || '')}</div>
        <div class="tags">${(script.hashtags || []).map((t) => `<span class="chip static">${esc(t)}</span>`).join('')}</div></section>
      <section><div class="kilabel">${icon('i-alert')}Beim Upload in TikTok „KI-generierte Inhalte“ einschalten.</div></section>
      ${(m.hinweise || []).length ? `<section><h3>Vor dem Upload prüfen</h3><ul class="list warnlist">${m.hinweise.map((h) => `<li><i class="dot warn"></i><span>${esc(h)}</span></li>`).join('')}</ul></section>` : ''}
      <section><h3>Quellen</h3><ul class="list">${(m.quellen || []).map((q) => {
        const c = checks[q.url];
        const state = !c || c.erreichbar == null ? 'off' : c.erreichbar ? '' : 'bad';
        const link = /^https?:\/\//.test(q.url) ? `<a href="${esc(q.url)}" target="_blank" rel="noopener noreferrer">${esc(q.quelle || q.url)}</a>` : esc(q.quelle);
        return `<li><i class="dot ${state}" title="${state === 'bad' ? 'nicht erreichbar' : state === 'off' ? 'nicht geprüft' : 'erreichbar'}"></i><span>${esc(q.fakt)}<br>${link}</span></li>`;
      }).join('') || '<li><i class="dot off"></i><span>Keine Quellen im Skript.</span></li>'}</ul></section>
      <section><h3>Bildmaterial</h3><div class="chips">${Object.entries(credits).map(([name, n]) => `<span class="chip static">${esc(name)} · ${n}</span>`).join('')}</div></section>
      <div class="sheet-foot"><button class="btn" data-open="${esc(item.folder)}">${icon('i-folder')}Ordner öffnen</button></div>
    </div>`;
}

function sheetScript(item) {
  const s = item.skript;
  return `<button class="icon-btn sheet-close" data-close aria-label="Schließen">${icon('i-close')}</button>
    <div class="sheet-body selectable" style="grid-column:1/-1">
      <h2>${esc(s.titel || s.hook)}</h2>
      <section><h3>Sprechertext<button class="btn btn-small" data-copy="${esc(item.sprechertext)}">${icon('i-copy')}Kopieren</button></h3><div class="textbox">${esc(item.sprechertext)}</div></section>
      <p class="hint" style="margin-top:14px">Einsprechen, dann im Studio unter „Eigenes Skript“ die Datei skript.json und deine Aufnahme auswählen.</p>
      <div class="sheet-foot"><button class="btn" data-open="${esc(item.folder)}">${icon('i-folder')}Ordner öffnen</button></div>
    </div>`;
}

async function openSheet(folder) {
  let item;
  try { item = await api(`/api/library/item?folder=${encodeURIComponent(folder)}`); } catch (err) { return toast(err.message, 'bad'); }
  const sheet = $('#sheet');
  sheet.style.cssText = '';
  sheet.innerHTML = item.kind === 'video' ? sheetVideo(item) : sheetScript(item);
  sheet.hidden = false;
  $('#scrim').hidden = false;
  return null;
}
function closeSheet() {
  const sheet = $('#sheet');
  $('video', sheet)?.pause();
  sheet.hidden = true;
  sheet.innerHTML = '';
  $('#scrim').hidden = true;
}

// ───────────────────────────── Einstellungen ─────────────────────────────
const KEY_ROWS = [
  ['ANTHROPIC_API_KEY', 'Claude', 'Skripte, Themen, Trends', 'https://console.anthropic.com/settings/keys'],
  ['AZURE_SPEECH_KEY', 'Azure AI Speech', 'Standard-Stimme', 'https://portal.azure.com'],
  ['PIXABAY_API_KEY', 'Pixabay', 'B-Roll-Clips und Fotos', 'https://pixabay.com/api/docs/'],
  ['PEXELS_API_KEY', 'Pexels', 'optional – neue Schlüssel derzeit pausiert', 'https://www.pexels.com/api/'],
  ['ELEVENLABS_API_KEY', 'ElevenLabs', 'optionale Stimme', 'https://elevenlabs.io/app/settings/api-keys'],
];

function renderSettings() {
  const st = S.data.settings;
  const sys = S.data.system;
  const p = S.data.prefs;
  const val = (name) => esc(st[name]?.value ?? '');
  const textRow = (name, label, hint = '') => `<div class="frow"><label>${label}${hint ? `<small>${hint}</small>` : ''}</label>
    <label class="field"><input data-setting="${name}" value="${val(name)}" spellcheck="false" autocomplete="off"></label></div>`;
  const check = (ok, title, text, state) => `<div class="check"><i class="dot ${state ?? (ok ? '' : 'bad')}"></i><div><b>${title}</b><small>${esc(text)}</small></div></div>`;
  const musicText = sys.music_total ? Object.entries(sys.music).map(([mood, n]) => `${mood}: ${n}`).join(' · ') : 'Noch keine Tracks in assets/music/ – Videos entstehen ohne Hintergrundmusik.';
  $('#view-settings').innerHTML = `<div class="page">
    <header class="page-head"><div><h1>Einstellungen</h1><p class="sub">Schlüssel bleiben auf deinem Rechner (Datei .env) und werden hier nie im Klartext angezeigt.</p></div></header>
    <div class="sgrid">
      <div>
        <section class="scard glass" id="card-keys">
          <h3><span class="orb">${icon('i-key')}</span>Schlüssel</h3><p class="sub">Leere Felder bleiben unverändert.</p>
          ${KEY_ROWS.map(([name, label, hint, url]) => `<div class="frow"><label>${label}<small>${hint}</small></label><div>
              <label class="field"><input type="password" data-setting="${name}" placeholder="${st[name].set ? `gespeichert ${esc(st[name].hint)}` : 'Schlüssel einfügen'}" autocomplete="off" spellcheck="false"></label>
              <div class="keymeta"><i class="dot ${st[name].set ? '' : (['ELEVENLABS_API_KEY', 'PEXELS_API_KEY'].includes(name) ? 'off' : 'bad')}"></i>${st[name].set ? 'vorhanden' : (['ELEVENLABS_API_KEY', 'PEXELS_API_KEY'].includes(name) ? 'nicht gesetzt (optional)' : 'fehlt')}
                · <a href="${url}" target="_blank" rel="noopener noreferrer">Schlüssel holen</a>
                ${st[name].set ? `· <button class="linkbtn" data-check="${{ ANTHROPIC_API_KEY: 'anthropic', AZURE_SPEECH_KEY: 'azure', PEXELS_API_KEY: 'pexels', PIXABAY_API_KEY: 'pixabay', ELEVENLABS_API_KEY: 'elevenlabs' }[name]}">Verbindung testen</button>` : ''}</div></div></div>`).join('')}
          <footer><button class="btn-primary small" data-save="card-keys">${icon('i-check')}Speichern</button></footer>
        </section>
        <section class="scard glass" id="card-voice" style="margin-top:16px">
          <h3><span class="orb">${icon('i-mic')}</span>Stimme &amp; Skript</h3><p class="sub">Gilt für alle neuen Aufträge.</p>
          <div class="frow"><label>Stimmen-Anbieter</label><div><div class="seg" data-seg="TTS_PROVIDER"><span class="seg-thumb"></span><button data-value="azure">Azure</button><button data-value="elevenlabs">ElevenLabs</button></div></div></div>
          ${textRow('AZURE_SPEECH_REGION', 'Azure-Region', 'z. B. westeurope')}
          ${textRow('AZURE_SPEECH_RATE', 'Sprechtempo', '+5% = etwas zügiger')}
          ${textRow('ELEVENLABS_VOICE_ID', 'ElevenLabs-Stimme', 'Voice-ID')}
          ${textRow('ANTHROPIC_MODEL', 'Claude-Modell')}
          <div class="frow"><label>Denktiefe</label><div><div class="seg" data-seg="ANTHROPIC_EFFORT"><span class="seg-thumb"></span><button data-value="low">niedrig</button><button data-value="medium">mittel</button><button data-value="high">hoch</button></div></div></div>
          <div class="frow"><label>Faktenrecherche<small>Websuche vor dem Schreiben</small></label><div><button class="toggle" role="switch" data-bool="SCRIPT_WEB_SEARCH" aria-checked="${st.SCRIPT_WEB_SEARCH.value !== 'false'}"><i class="switch"></i>echte Quellen suchen</button></div></div>
          <footer><button class="btn-primary small" data-save="card-voice">${icon('i-check')}Speichern</button></footer>
        </section>
      </div>
      <div>
        <section class="scard glass">
          <h3><span class="orb">${icon('i-eye')}</span>Darstellung</h3><p class="sub">Wird sofort übernommen.</p>
          <div class="frow"><label>Farbschema</label><div><div class="seg" id="seg-theme"><span class="seg-thumb"></span><button data-value="dark">Dunkel</button><button data-value="light">Hell</button></div></div></div>
          <div class="frow"><label>Glas-Stärke<small>${BOOT.shell.backdrop === 'opaque' ? 'Leuchtkraft des Hintergrunds' : 'wie viel vom Desktop durchscheint'}</small></label><input type="range" id="pref-glass" min="0" max="100" value="${p.glass}"></div>
          <div class="frow"><label>Akzentfarbe</label><div class="swatches">${Object.entries(ACCENTS).map(([name, c]) => `<button class="swatch ${p.accent === name ? 'is-active' : ''}" data-accent="${name}" title="${name}" style="background:linear-gradient(135deg,${c[0]},${c[1]} 55%,${c[2]})"></button>`).join('')}</div></div>
          <div class="frow"><label>Bewegung</label><div><button class="toggle" role="switch" data-pref="motion" aria-checked="${p.motion}"><i class="switch"></i>Animationen</button></div></div>
          <div class="frow desktop-only"><label>Fenster<small>wirkt nach Neustart</small></label><div><button class="toggle" role="switch" data-pref="transparent" aria-checked="${p.transparent}"><i class="switch"></i>durchscheinend</button></div></div>
          ${BOOT.shell.platform === 'win32' ? `<div class="frow desktop-only"><label>Unschärfe<small>Acrylic, wirkt nach Neustart</small></label><div><button class="toggle" role="switch" data-pref="blur" aria-checked="${p.blur}"><i class="switch"></i>Desktop weichzeichnen</button></div></div>` : ''}
        </section>
        <section class="scard glass" style="margin-top:16px">
          <h3><span class="orb">${icon('i-check')}</span>System</h3><p class="sub">Was die Pipeline auf diesem Rechner vorfindet.</p>
          <div class="checks">
            ${check(sys.ffmpeg.ok, 'ffmpeg', sys.ffmpeg.text)}
            ${check(sys.font, 'Untertitel-Schrift', sys.font ? 'Poppins Black liegt bei' : 'assets/fonts/Poppins-Black.ttf fehlt')}
            ${check(true, 'Wort-Zeitstempel', sys.whisper.cached ? `faster-whisper „${sys.whisper.model}“ ist geladen` : `faster-whisper „${sys.whisper.model}“ wird beim ersten Video geladen (ca. 500 MB)`, sys.whisper.cached ? '' : 'warn')}
            ${check(true, 'Musik', musicText, sys.music_total ? '' : 'warn')}
            ${check(true, 'Ausgabeordner', sys.output, 'off')}
          </div>
          <div class="frow" style="margin-top:8px"><label>Automatik<small>beim Start und alle 30 min</small></label><div><button class="toggle" role="switch" data-pref="auto_refresh" aria-checked="${p.auto_refresh}"><i class="switch"></i>Trends und Nischen aktuell halten</button></div></div>
          <div class="frow"><label>Ohne Whisper<small>nur zum Testen</small></label><div><button class="toggle" role="switch" id="opt-nowhisper" aria-checked="${!S.form.whisper}"><i class="switch"></i>Wortzeiten schätzen</button></div></div>
          <footer><button class="btn btn-small" id="sys-check">${icon('i-refresh')}Erneut prüfen</button></footer>
        </section>
      </div>
    </div></div>`;
  $$('[data-seg]', $('#view-settings')).forEach((el) => initSeg(el, st[el.dataset.seg].value, () => {}));
  initSeg($('#seg-theme'), p.theme === 'light' ? 'light' : 'dark', (v) => setPref('theme', v));
}

async function saveCard(cardId) {
  const card = document.getElementById(cardId);
  const values = {};
  $$('input[data-setting]', card).forEach((inp) => { if (inp.type !== 'password' || inp.value.trim()) values[inp.dataset.setting] = inp.value.trim(); });
  $$('[data-seg]', card).forEach((el) => { values[el.dataset.seg] = $('button.is-active', el)?.dataset.value; });
  $$('[data-bool]', card).forEach((el) => { values[el.dataset.bool] = el.getAttribute('aria-checked') === 'true' ? 'true' : 'false'; });
  try {
    const res = await api('/api/settings', { body: { values } });
    Object.assign(S.data, res);
    renderSettings();
    renderOptions();
    updateCta();
    toast('Gespeichert');
  } catch (err) {
    toast(err.message, 'bad');
  }
}

// ───────────────────────────── Protokoll ─────────────────────────────
function appendLog(lines) {
  const log = $('#log');
  const stick = log.scrollTop + log.clientHeight >= log.scrollHeight - 30;
  log.insertAdjacentHTML('beforeend', lines.map((l) => {
    const time = new Date(l.t * 1000).toLocaleTimeString('de-DE');
    return `<div class="${esc(l.level)}"><time>${time}</time>${esc(l.msg)}</div>`;
  }).join(''));
  while (log.childElementCount > 1200) log.firstElementChild.remove();
  if (stick) log.scrollTop = log.scrollHeight;
}
function toggleLog(show) {
  const drawer = $('#logdrawer');
  drawer.hidden = show === undefined ? !drawer.hidden : !show;
  if (!drawer.hidden) $('#log').scrollTop = $('#log').scrollHeight;
}

// ───────────────────────────── Mini-Overlay ─────────────────────────────
function renderCompact() {
  $('#compact').innerHTML = `<div class="ccard glass">
    <div class="ctop"><div class="brand pywebview-drag-region"><span class="brand-mark"><svg viewBox="0 0 24 24"><path d="M8.5 5.5v13l11-6.5z"/></svg></span><span class="brand-name">Factory</span></div>
      <span class="cstatus" id="c-status">Bereit</span>
      <button class="icon-btn" id="c-expand" title="Großes Fenster" aria-label="Großes Fenster">${icon('i-expand')}</button>
      <button class="icon-btn win-close desktop-only" data-win="close" aria-label="Schließen">${icon('i-close')}</button></div>
    <div class="crow"><label class="field"><input id="c-topic" maxlength="240" placeholder="Thema eingeben und Enter drücken …" autocomplete="off"></label>
      <button class="btn-primary" id="c-go">${icon('i-play', 'solid')}<span>Erzeugen</span></button></div>
    <div class="cbar"><i id="c-bar"></i></div></div>`;
  const go = async () => {
    const topic = $('#c-topic').value.trim();
    if (topic.length < 4) return toast('Bitte ein Thema eingeben.', 'bad');
    try {
      const res = await api('/api/jobs', { body: { mode: 'topic', topic, niche: S.form.niche, lang: S.form.lang, music: S.form.music, whisper: S.form.whisper } });
      S.focus = res.ids[0];
      $('#c-topic').value = '';
      toast('Gestartet');
      await poll();
    } catch (err) {
      toast(err.message, 'bad');
    }
    return null;
  };
  $('#c-go').addEventListener('click', go);
  $('#c-topic').addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
  $('#c-expand').addEventListener('click', () => setCompact(false));
}
async function setCompact(on) {
  S.compact = on;
  html.dataset.compact = on ? '1' : '0';
  $('#compact').hidden = !on;
  await win('set_compact', on);
  if (on) $('#c-topic').focus();
  else requestAnimationFrame(placeSegs);
  renderStatus();
}

// ───────────────────────────── Ansichten / Laden ─────────────────────────────
async function reload(what) {
  try {
    if (what === 'library') { S.data.library = (await api('/api/library')).items; renderLibrary(); }
    if (what === 'trends') {
      const [trends, niches] = await Promise.all([api('/api/trends'), api('/api/niches')]);
      S.data.trends = trends;
      Object.assign(S.data, niches);
      renderTrends();
      renderModeBody();
      updateCta();
    }
    if (what === 'settings') { Object.assign(S.data, await api('/api/settings')); renderSettings(); updateCta(); }
  } catch (err) {
    toast(err.message, 'bad');
  }
}
function showView(name) {
  S.view = name;
  $$('.view').forEach((v) => {
    const on = v.dataset.view === name;
    v.hidden = !on;
    if (on) { v.classList.remove('enter'); void v.offsetWidth; v.classList.add('enter'); }
  });
  $('#nav')._set(name);
  if (name !== 'studio') reload(name);
  requestAnimationFrame(placeSegs);
}

// ───────────────────────────── Zustand abfragen ─────────────────────────────
let pollTimer = null;
async function poll() {
  clearTimeout(pollTimer);
  try {
    const st = await api(`/api/state?since=${S.seq}`);
    S.offline = false;
    if (st.log.length) { S.seq = st.seq; appendLog(st.log); }
    if (st.rev !== S.rev) {
      const before = Object.fromEntries(S.jobs.map((j) => [j.id, j.status]));
      S.jobs = st.jobs;
      S.rev = st.rev;
      for (const job of S.jobs) {
        if (before[job.id] === undefined || before[job.id] === job.status) continue;
        if (job.status === 'fertig') {
          toast(`Fertig: ${job.title}`);
          reload('library');
          if (job.kind === 'trends' || job.kind === 'nischen' || job.mode === 'trend') reload('trends');
        } else if (job.status === 'fehler') {
          toast(`Fehlgeschlagen: ${job.title}`, 'bad');
        }
      }
      renderStage();
      if (S.view === 'trends') renderTrends();
    }
  } catch {
    S.offline = true;
  }
  renderStatus();
  pollTimer = setTimeout(poll, busyJobs().length ? 500 : 1800);
}

// ───────────────────────────── Ereignisse ─────────────────────────────
function bindGlobal() {
  document.addEventListener('click', (e) => {
    const pick = (sel) => e.target.closest(sel);
    let b;
    if ((b = pick('[data-win]'))) {
      if (b.dataset.win === 'close') closeWindow();
      else win(b.dataset.win === 'maximize' ? 'toggle_maximize' : 'minimize');
    } else if ((b = pick('[data-goto]'))) showView(b.dataset.goto);
    else if ((b = pick('[data-detail]'))) openSheet(b.dataset.detail);
    else if ((b = pick('[data-open]'))) api('/api/open', { body: { folder: b.dataset.open } }).catch((err) => toast(err.message, 'bad'));
    else if ((b = pick('[data-copy]'))) copyText(b.dataset.copy);
    else if ((b = pick('[data-close]')) || e.target.id === 'scrim') closeSheet();
    else if ((b = pick('[data-log]')) || pick('#status') || pick('#btn-log')) toggleLog();
    else if ((b = pick('[data-produce]'))) produceTrend(Number(b.dataset.produce));
    else if (pick('#trends-refresh')) refreshTrends();
    else if (pick('#niches-discover')) nicheAction('/api/niches/discover', null, 'Nischen-Suche gestartet');
    else if ((b = pick('[data-niche-add]'))) nicheAction('/api/niches/add', b.dataset.nicheAdd, 'Nische übernommen – im Studio wählbar');
    else if ((b = pick('[data-niche-remove]'))) nicheAction('/api/niches/remove', b.dataset.nicheRemove, 'Nische entfernt');
    else if ((b = pick('[data-check]'))) checkService(b);
    else if ((b = pick('[data-save]'))) saveCard(b.dataset.save);
    else if ((b = pick('[data-accent]'))) { setPref('accent', b.dataset.accent); $$('.swatch').forEach((s) => s.classList.toggle('is-active', s === b)); }
    else if ((b = pick('[data-pref]'))) { const on = b.getAttribute('aria-checked') !== 'true'; b.setAttribute('aria-checked', on); setPref(b.dataset.pref, on); if (b.dataset.pref === 'motion' && !$('#demo-cap')) return; if (b.dataset.pref === 'motion') startDemo(); }
    else if ((b = pick('[data-bool]'))) b.setAttribute('aria-checked', b.getAttribute('aria-checked') !== 'true');
    else if (pick('#opt-nowhisper')) { S.form.whisper = !S.form.whisper; $('#opt-nowhisper').setAttribute('aria-checked', !S.form.whisper); }
    else if (pick('#sys-check')) reload('settings').then(() => toast('Geprüft'));
    else if (pick('#log-close')) toggleLog(false);
    else if (pick('#log-copy')) copyText($('#log').innerText, 'Protokoll kopiert');
    else if (pick('#btn-compact')) setCompact(true);
    else if ((b = pick('#btn-pin'))) {
      const on = b.getAttribute('aria-pressed') !== 'true';
      b.setAttribute('aria-pressed', on);
      S.data.prefs.on_top = on;
      win('set_on_top', on);
    }
  });
  document.addEventListener('input', (e) => { if (e.target.id === 'pref-glass') setPref('glass', Number(e.target.value)); });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      if (!$('#sheet').hidden) closeSheet();
      else if (!$('#logdrawer').hidden) toggleLog(false);
      else if (S.compact) setCompact(false);
    }
    const views = ['studio', 'trends', 'library', 'settings'];
    if ((e.metaKey || e.ctrlKey) && /^[1-4]$/.test(e.key) && !S.compact) { e.preventDefault(); showView(views[Number(e.key) - 1]); }
  });
  $('#drag').addEventListener('dblclick', () => win('toggle_maximize'));
  window.addEventListener('resize', placeSegs);
  document.fonts?.ready.then(placeSegs);

  // Glanz folgt dem Mauszeiger
  let lit = null;
  document.addEventListener('pointermove', (e) => {
    const glass = e.target.closest?.('.glass') || null;
    if (glass !== lit) { lit?.style.setProperty('--sheen', '0'); lit = glass; }
    if (!glass) return;
    const r = glass.getBoundingClientRect();
    glass.style.setProperty('--mx', `${e.clientX - r.left}px`);
    glass.style.setProperty('--my', `${e.clientY - r.top}px`);
    glass.style.setProperty('--sheen', '1');
  }, { passive: true });

  // Größe ändern (rahmenlose Fenster unter Windows/Linux haben keinen Rand zum Ziehen)
  const grip = $('#resize-grip');
  grip.addEventListener('pointerdown', (e) => {
    grip.setPointerCapture(e.pointerId);
    const start = { x: e.screenX, y: e.screenY, w: window.outerWidth || window.innerWidth, h: window.outerHeight || window.innerHeight };
    let next = null;
    let sending = false;
    const send = async () => {
      sending = true;
      while (next) { const [w, h] = next; next = null; await win('resize', w, h); }
      sending = false;
    };
    const move = (ev) => { next = [Math.round(start.w + ev.screenX - start.x), Math.round(start.h + ev.screenY - start.y)]; if (!sending) send(); };
    const up = () => { grip.removeEventListener('pointermove', move); grip.removeEventListener('pointerup', up); };
    grip.addEventListener('pointermove', move);
    grip.addEventListener('pointerup', up);
  });
}

// ───────────────────────────── Start ─────────────────────────────
async function init() {
  html.dataset.mode = BOOT.shell.mode;
  html.dataset.platform = BOOT.shell.platform;
  html.dataset.backdrop = BOOT.shell.backdrop;
  try {
    S.data = await api('/api/bootstrap');
  } catch (err) {
    document.body.insertAdjacentHTML('beforeend', `<p style="position:fixed;inset:0;display:grid;place-items:center;color:#fff;font:600 15px system-ui">${esc(err.message)}</p>`);
    return;
  }
  S.jobs = S.data.state.jobs;
  S.rev = S.data.state.rev;
  S.form.niche = evergreen().some((n) => n.key === 'psychologie') ? 'psychologie' : (evergreen()[0]?.key || S.data.default_niche);
  applyPrefs();
  $('#traffic').hidden = !(BOOT.shell.platform === 'darwin' && BOOT.shell.mode === 'desktop');
  $('#btn-pin').setAttribute('aria-pressed', Boolean(S.data.prefs.on_top));
  initSeg($('#nav'), 'studio', showView);
  renderStudio();
  renderTrends();
  renderLibrary();
  renderSettings();
  renderCompact();
  bindGlobal();
  watchLenses();
  poll();
}

init();
