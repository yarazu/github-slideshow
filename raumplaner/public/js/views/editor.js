import { api, del, post, put } from '../api.js';
import { planBackground, planDefs, roomLabel, shapeBBox, shapeElement } from '../floorplan.js';
import { buildingById, floorById, KIND_LABEL, loadLayout, state } from '../state.js';
import { confirmDialog, debounce, emptyState, h, icon, s, toast, toastError } from '../ui.js';
import { floorDialog } from './admin.js';

const MIME_BY_EXT = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', webp: 'image/webp', gif: 'image/gif', svg: 'image/svg+xml' };
const clone = (o) => JSON.parse(JSON.stringify(o));

function stored(key, fallback) {
  try {
    const v = localStorage.getItem(key);
    return v === null ? fallback : JSON.parse(v);
  } catch {
    return fallback;
  }
}

function store(key, value) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    /* egal */
  }
}

function nextName(name, taken) {
  const m = /^(.*?)(\d+)$/.exec(name);
  if (m) {
    for (let i = Number(m[2]) + 1; i < 10000; i++) {
      const candidate = `${m[1]}${i}`;
      if (!taken.has(candidate)) return candidate;
    }
  }
  let candidate = `${name} (Kopie)`;
  for (let i = 2; taken.has(candidate); i++) candidate = `${name} (Kopie ${i})`;
  return candidate;
}

export async function renderEditor(root, { params }) {
  let floor = floorById(Number(params[0]));
  if (!floor) {
    root.append(h('div', { class: 'card' }, emptyState('map', 'Etage nicht gefunden', null, [h('a', { class: 'btn', href: '#/admin/gebaeude' }, 'Zurück zur Verwaltung')])));
    return;
  }
  const building = buildingById(floor.buildingId);
  const st = {
    rooms: clone(state.layout.rooms.filter((r) => r.floorId === floor.id)),
    tool: 'select',
    selectedId: null,
    placingId: null,
    grid: stored('rp.ed.grid', true),
    gridSize: stored('rp.ed.gridSize', 10),
    zoom: 1,
    drawing: null,
    drag: null,
  };
  const selected = () => st.rooms.find((r) => r.id === st.selectedId) || null;

  // ---------------------------------------------------------------- Speichern-Status
  const saved = h('span', { class: 'saved-state' }, icon('check'), 'Alles gespeichert');
  let pending = 0;
  function saving(delta, error) {
    pending = Math.max(0, pending + delta);
    saved.className = `saved-state${error ? ' error' : pending ? ' saving' : ''}`;
    saved.replaceChildren(icon(error ? 'alert' : pending ? 'clock' : 'check'), error ? 'Fehler beim Speichern' : pending ? 'Speichere …' : 'Alles gespeichert');
  }

  function syncGlobal(room) {
    const i = state.layout.rooms.findIndex((r) => r.id === room.id);
    if (i >= 0) state.layout.rooms[i] = clone(room);
    else state.layout.rooms.push(clone(room));
  }

  async function saveRoom(room, patch) {
    saving(1);
    try {
      const res = await put(`/api/rooms/${room.id}`, patch);
      Object.assign(room, res);
      syncGlobal(room);
      saving(-1);
      return res;
    } catch (err) {
      saving(-1, true);
      toastError(err, 'Speichern fehlgeschlagen');
      await reloadRooms();
      return null;
    }
  }

  async function reloadRooms() {
    await loadLayout();
    floor = floorById(floor.id) || floor;
    st.rooms = clone(state.layout.rooms.filter((r) => r.floorId === floor.id));
    draw();
    renderPanel();
  }

  // ---------------------------------------------------------------- Werkzeugleiste
  const toolButtons = {};
  const setTool = (tool) => {
    st.tool = tool;
    st.drawing = null;
    if (tool !== 'rect' && tool !== 'poly') st.placingId = null;
    for (const [k, b] of Object.entries(toolButtons)) b.classList.toggle('active', k === tool);
    canvas.className = `editor-canvas tool-${tool}`;
    hint.textContent = {
      select: 'Raum anklicken zum Bearbeiten · ziehen zum Verschieben · Griffe ziehen zum Ändern der Größe · Pfeiltasten verschieben fein.',
      rect: 'Im Plan klicken und ziehen, um ein Rechteck zu zeichnen.',
      poly: 'Eckpunkte nacheinander anklicken · Doppelklick, Enter oder Klick auf den ersten Punkt schließt die Form · Esc bricht ab.',
    }[tool];
    draw();
  };
  const toolBtn = (key, ic, label, shortcut) => {
    toolButtons[key] = h('button', { class: 'btn btn-sm', type: 'button', title: `${label} (${shortcut})`, onClick: () => setTool(key) }, icon(ic), label);
    return toolButtons[key];
  };
  const gridIn = h('input', { type: 'checkbox', checked: st.grid });
  const gridSizeSel = h('select', { class: 'input', style: { width: 'auto', minHeight: '32px', padding: '4px 8px' }, 'aria-label': 'Rasterweite' }, [5, 10, 20, 25, 50].map((g) => h('option', { value: String(g) }, `${g}`)));
  gridSizeSel.value = String(st.gridSize);
  gridIn.addEventListener('change', () => {
    st.grid = gridIn.checked;
    store('rp.ed.grid', st.grid);
    draw();
  });
  gridSizeSel.addEventListener('change', () => {
    st.gridSize = Number(gridSizeSel.value);
    store('rp.ed.gridSize', st.gridSize);
    draw();
  });
  const zoomLabel = h('span', { class: 'small muted', style: { minWidth: '44px', textAlign: 'center' } }, '100 %');
  const setZoom = (z) => {
    st.zoom = Math.min(4, Math.max(0.25, z));
    zoomLabel.textContent = `${Math.round(st.zoom * 100)} %`;
    draw();
  };
  const hint = h('p', { class: 'muted small', style: { padding: '8px 12px 0' } });

  const tools = h(
    'div',
    { class: 'editor-tools' },
    h('div', { class: 'btn-group' }, toolBtn('select', 'pointer', 'Auswählen', 'V'), toolBtn('rect', 'square', 'Rechteck', 'R'), toolBtn('poly', 'polygon', 'Polygon', 'P')),
    h('span', { class: 'sep' }),
    h('label', { class: 'check small', style: { alignItems: 'center' } }, gridIn, 'Raster'),
    gridSizeSel,
    h('span', { class: 'sep' }),
    h('button', { class: 'btn btn-sm btn-icon', type: 'button', 'aria-label': 'Verkleinern', onClick: () => setZoom(st.zoom / 1.25) }, icon('zoomOut')),
    zoomLabel,
    h('button', { class: 'btn btn-sm btn-icon', type: 'button', 'aria-label': 'Vergrößern', onClick: () => setZoom(st.zoom * 1.25) }, icon('zoomIn')),
    h('button', { class: 'btn btn-sm', type: 'button', onClick: () => setZoom(1) }, 'Einpassen'),
    h('span', { style: { marginLeft: 'auto' } }, saved),
  );

  // ---------------------------------------------------------------- Grundriss-Bild
  const fileIn = h('input', { type: 'file', accept: 'image/png,image/jpeg,image/webp,image/gif,image/svg+xml', hidden: true });
  fileIn.addEventListener('change', async () => {
    const file = fileIn.files[0];
    fileIn.value = '';
    if (!file) return;
    if (file.size > 15 * 1024 * 1024) {
      toast('Die Datei ist zu groß (max. 15 MB).', { type: 'error' });
      return;
    }
    const type = file.type || MIME_BY_EXT[file.name.split('.').pop().toLowerCase()] || '';
    if (!Object.values(MIME_BY_EXT).includes(type)) {
      toast('Bitte ein Bild hochladen (PNG, JPG, WebP, GIF oder SVG).', { type: 'error', body: 'Tipp: PDF-Pläne vorher als PNG exportieren.' });
      return;
    }
    let natural = { w: 0, h: 0 };
    try {
      const url = URL.createObjectURL(file);
      natural = await new Promise((resolve, reject) => {
        const img = new Image();
        img.onload = () => resolve({ w: img.naturalWidth, h: img.naturalHeight });
        img.onerror = reject;
        img.src = url;
      });
      URL.revokeObjectURL(url);
    } catch {
      /* Größe unbekannt – Plangröße bleibt */
    }
    const width = floor.width;
    const height = natural.w && natural.h ? Math.min(10000, Math.max(100, Math.round((width * natural.h) / natural.w))) : floor.height;
    saving(1);
    try {
      floor = await api('PUT', `/api/floors/${floor.id}/image?width=${width}&height=${height}`, file, { raw: true, headers: { 'Content-Type': type } });
      await loadLayout();
      saving(-1);
      toast('Grundriss hochgeladen', { type: 'success', body: 'Zeichne jetzt die Räume auf dem Plan ein.' });
      renderHead();
      draw();
    } catch (err) {
      saving(-1, true);
      toastError(err);
    }
  });

  const headActions = h('div', { class: 'row' });
  const subtitle = h('p');
  function renderHead() {
    subtitle.textContent = `${building?.name || ''} · Plangröße ${floor.width} × ${floor.height}`;
    headActions.replaceChildren(...[
      h('button', { class: 'btn', type: 'button', onClick: () => fileIn.click() }, icon('upload'), floor.imageUrl ? 'Grundriss ersetzen' : 'Grundriss hochladen'),
      floor.imageUrl
        ? h(
            'button',
            {
              class: 'btn btn-ghost',
              type: 'button',
              onClick: async () => {
                if (!(await confirmDialog('Das Grundrissbild entfernen? Die eingezeichneten Räume bleiben erhalten.', { confirmLabel: 'Entfernen', danger: true }))) return;
                try {
                  floor = await del(`/api/floors/${floor.id}/image`);
                  await loadLayout();
                  renderHead();
                  draw();
                } catch (err) {
                  toastError(err);
                }
              },
            },
            'Bild entfernen',
          )
        : null,
      h(
        'button',
        {
          class: 'btn btn-ghost',
          type: 'button',
          onClick: () =>
            floorDialog({ floor }, async (res) => {
              floor = res;
              await loadLayout();
              renderHead();
              draw();
            }),
        },
        icon('sliders'),
        'Etage',
      ),
      h('a', { class: 'btn btn-primary', href: `#/finden?floor=${floor.id}` }, icon('eye'), 'Im Lageplan ansehen'),
      fileIn,
    ].filter(Boolean));
  }

  root.append(
    h(
      'div',
      { class: 'page-head' },
      h(
        'div',
        null,
        h('a', { href: '#/admin/gebaeude', class: 'small', style: { display: 'inline-flex', alignItems: 'center', gap: '4px' } }, icon('left'), 'Gebäude & Pläne'),
        h('h1', null, `Grundriss: ${floor.name}`),
        subtitle,
      ),
      headActions,
    ),
  );
  renderHead();

  const canvas = h('div', { class: 'editor-canvas tool-select' });
  const svg = s('svg', { role: 'application', 'aria-label': `Grundriss-Editor ${floor.name}` });
  canvas.append(svg);
  const panel = h('div', { class: 'card' });
  root.append(h('div', { class: 'editor' }, h('div', { class: 'card' }, tools, hint, canvas), panel));

  // ---------------------------------------------------------------- Geometrie
  const snap = (v) => (st.grid ? Math.round(v / st.gridSize) * st.gridSize : Math.round(v));
  const clampX = (v) => Math.min(Math.max(v, 0), floor.width);
  const clampY = (v) => Math.min(Math.max(v, 0), floor.height);
  const pxScale = () => (svg.getBoundingClientRect().width || 1) / floor.width;

  function toPlan(e) {
    const pt = svg.createSVGPoint();
    pt.x = e.clientX;
    pt.y = e.clientY;
    const p = pt.matrixTransform(svg.getScreenCTM().inverse());
    return [p.x, p.y];
  }

  function moveShape(o, dx, dy) {
    if (o.type === 'rect') return { ...o, x: snap(o.x + dx), y: snap(o.y + dy) };
    const nx = snap(o.points[0][0] + dx) - o.points[0][0];
    const ny = snap(o.points[0][1] + dy) - o.points[0][1];
    return { type: 'poly', points: o.points.map(([x, y]) => [x + nx, y + ny]) };
  }

  function resizeRect(o, handle, [px, py]) {
    let x1 = o.x;
    let y1 = o.y;
    let x2 = o.x + o.w;
    let y2 = o.y + o.h;
    if (handle.includes('w')) x1 = px;
    if (handle.includes('e')) x2 = px;
    if (handle.includes('n')) y1 = py;
    if (handle.includes('s')) y2 = py;
    return { type: 'rect', x: Math.min(x1, x2), y: Math.min(y1, y2), w: Math.max(1, Math.abs(x2 - x1)), h: Math.max(1, Math.abs(y2 - y1)) };
  }

  // ---------------------------------------------------------------- Zeichnen
  function draw() {
    const fit = Math.max(320, canvas.clientWidth - 26);
    const widthPx = fit * st.zoom;
    svg.setAttribute('viewBox', `0 0 ${floor.width} ${floor.height}`);
    svg.setAttribute('width', String(Math.round(widthPx)));
    svg.setAttribute('height', String(Math.round((widthPx * floor.height) / floor.width)));
    const scale = widthPx / floor.width;
    const r = 5 / scale;
    const base = Math.max(floor.width, floor.height) / 55;

    const parts = [planDefs(), ...planBackground(floor, { grid: false })];
    if (st.grid) {
      parts.push(
        s(
          'defs',
          null,
          s(
            'pattern',
            { id: 'ed-grid', width: st.gridSize, height: st.gridSize, patternUnits: 'userSpaceOnUse' },
            s('path', { d: `M ${st.gridSize} 0 L 0 0 0 ${st.gridSize}`, fill: 'none', class: 'plan-grid-line', 'stroke-width': 1 / scale }),
          ),
        ),
        s('rect', { x: 0, y: 0, width: floor.width, height: floor.height, fill: 'url(#ed-grid)', 'pointer-events': 'none' }),
      );
    }
    const ordered = [...st.rooms].filter((x) => x.shape).sort((a, b) => (a.kind === 'area' ? 0 : 1) - (b.kind === 'area' ? 0 : 1) || (a.id === st.selectedId ? 1 : 0) - (b.id === st.selectedId ? 1 : 0));
    for (const room of ordered) {
      const g = s('g', {
        class: `kind-${room.kind}${room.bookable ? '' : ' not-bookable'}${room.id === st.selectedId ? ' selected' : ''}`,
        'data-id': room.id,
      });
      g.append(shapeElement(room.shape, { class: 'room-shape' }), ...roomLabel(room.shape, [{ text: room.name }], base));
      parts.push(g);
    }
    const sel = selected();
    if (sel?.shape && st.tool === 'select') {
      if (sel.shape.type === 'rect') {
        const { x, y, w, h: hh } = sel.shape;
        const pts = { nw: [x, y], n: [x + w / 2, y], ne: [x + w, y], e: [x + w, y + hh / 2], se: [x + w, y + hh], s: [x + w / 2, y + hh], sw: [x, y + hh], w: [x, y + hh / 2] };
        for (const [k, [cx, cy]] of Object.entries(pts)) {
          parts.push(s('rect', { class: 'handle', x: cx - r, y: cy - r, width: 2 * r, height: 2 * r, 'data-handle': k, style: { cursor: `${k}-resize` } }));
        }
      } else {
        const p = sel.shape.points;
        p.forEach(([cx, cy], i) => {
          const [nx, ny] = p[(i + 1) % p.length];
          parts.push(s('circle', { class: 'handle', cx: (cx + nx) / 2, cy: (cy + ny) / 2, r: r * 0.7, 'data-mid': i, opacity: 0.55, style: { cursor: 'copy' } }));
        });
        p.forEach(([cx, cy], i) => parts.push(s('circle', { class: 'handle', cx, cy, r, 'data-vertex': i, style: { cursor: 'move' } })));
      }
    }
    if (st.drawing && st.tool === 'rect') {
      const d = st.drawing;
      parts.push(s('rect', { class: 'draft', x: Math.min(d.x0, d.x1), y: Math.min(d.y0, d.y1), width: Math.abs(d.x1 - d.x0), height: Math.abs(d.y1 - d.y0) }));
    }
    if (st.drawing && st.tool === 'poly') {
      const pts = [...st.drawing.points, st.drawing.hover].filter(Boolean);
      parts.push(s('polyline', { class: 'draft', points: pts.map((p) => p.join(',')).join(' ') }));
      st.drawing.points.forEach(([cx, cy], i) => parts.push(s('circle', { class: 'handle', cx, cy, r: i === 0 ? r * 1.4 : r })));
    }
    svg.replaceChildren(...parts);
  }

  // ---------------------------------------------------------------- Maus/Touch
  svg.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;
    const [px, py] = toPlan(e);
    const p = [clampX(snap(px)), clampY(snap(py))];
    if (st.tool === 'rect') {
      st.drawing = { x0: p[0], y0: p[1], x1: p[0], y1: p[1] };
      svg.setPointerCapture(e.pointerId);
      draw();
      return;
    }
    if (st.tool === 'poly') {
      if (!st.drawing) st.drawing = { points: [p], hover: p };
      else {
        const first = st.drawing.points[0];
        const dist = Math.hypot(first[0] - p[0], first[1] - p[1]) * pxScale();
        if (st.drawing.points.length >= 3 && dist < 12) {
          finishPolygon();
          return;
        }
        const last = st.drawing.points[st.drawing.points.length - 1];
        if (last[0] !== p[0] || last[1] !== p[1]) st.drawing.points.push(p);
      }
      draw();
      return;
    }
    const target = e.target;
    const room = selected();
    if (room && target.dataset?.handle) {
      st.drag = { mode: 'resize', handle: target.dataset.handle, orig: clone(room.shape), start: [px, py] };
    } else if (room && target.dataset?.vertex !== undefined) {
      st.drag = { mode: 'vertex', index: Number(target.dataset.vertex), orig: clone(room.shape), start: [px, py] };
    } else if (room && target.dataset?.mid !== undefined) {
      const i = Number(target.dataset.mid);
      const pts = room.shape.points;
      const [ax, ay] = pts[i];
      const [bx, by] = pts[(i + 1) % pts.length];
      pts.splice(i + 1, 0, [snap((ax + bx) / 2), snap((ay + by) / 2)]);
      st.drag = { mode: 'vertex', index: i + 1, orig: clone(room.shape), start: [px, py], moved: true };
    } else {
      const g = target.closest?.('g[data-id]');
      if (!g) {
        st.selectedId = null;
        renderPanel();
        draw();
        return;
      }
      st.selectedId = Number(g.dataset.id);
      renderPanel();
      st.drag = { mode: 'move', orig: clone(selected().shape), start: [px, py] };
    }
    svg.setPointerCapture(e.pointerId);
    draw();
  });

  svg.addEventListener('pointermove', (e) => {
    if (!st.drawing && !st.drag) return;
    const [px, py] = toPlan(e);
    if (st.tool === 'rect' && st.drawing) {
      st.drawing.x1 = clampX(snap(px));
      st.drawing.y1 = clampY(snap(py));
      draw();
      return;
    }
    if (st.tool === 'poly' && st.drawing) {
      st.drawing.hover = [clampX(snap(px)), clampY(snap(py))];
      draw();
      return;
    }
    const d = st.drag;
    const room = selected();
    if (!d || !room) return;
    const dx = px - d.start[0];
    const dy = py - d.start[1];
    if (!d.moved && Math.hypot(dx, dy) * pxScale() < 3) return;
    d.moved = true;
    if (d.mode === 'move') room.shape = moveShape(d.orig, dx, dy);
    else if (d.mode === 'resize') room.shape = resizeRect(d.orig, d.handle, [clampX(snap(px)), clampY(snap(py))]);
    else if (d.mode === 'vertex') room.shape.points[d.index] = [clampX(snap(px)), clampY(snap(py))];
    draw();
  });

  const endPointer = async (e) => {
    if (st.tool === 'rect' && st.drawing) {
      const d = st.drawing;
      st.drawing = null;
      const shape = { type: 'rect', x: Math.min(d.x0, d.x1), y: Math.min(d.y0, d.y1), w: Math.abs(d.x1 - d.x0), h: Math.abs(d.y1 - d.y0) };
      if (e.type !== 'pointercancel' && shape.w >= 5 && shape.h >= 5) await placeShape(shape);
      else draw();
      return;
    }
    const d = st.drag;
    st.drag = null;
    if (d?.moved && selected()) {
      renderPanel();
      await saveRoom(selected(), { shape: selected().shape });
    }
  };
  svg.addEventListener('pointerup', endPointer);
  svg.addEventListener('pointercancel', endPointer);
  svg.addEventListener('dblclick', (e) => {
    if (st.tool === 'poly' && st.drawing) {
      e.preventDefault();
      finishPolygon();
    } else if (st.tool === 'select' && selected()) {
      panel.querySelector('input')?.focus();
    }
  });

  async function finishPolygon() {
    const pts = [];
    for (const p of st.drawing?.points || []) {
      const last = pts[pts.length - 1];
      if (!last || last[0] !== p[0] || last[1] !== p[1]) pts.push(p);
    }
    st.drawing = null;
    if (pts.length < 3) {
      toast('Ein Polygon braucht mindestens 3 Eckpunkte.', { type: 'info', timeout: 3000 });
      draw();
      return;
    }
    await placeShape({ type: 'poly', points: pts });
  }

  async function placeShape(shape) {
    if (st.placingId) {
      const room = st.rooms.find((r) => r.id === st.placingId);
      st.placingId = null;
      if (room) {
        room.shape = shape;
        st.selectedId = room.id;
        setTool('select');
        renderPanel();
        await saveRoom(room, { shape });
        return;
      }
    }
    saving(1);
    try {
      const count = st.rooms.filter((r) => r.kind === 'room').length + 1;
      const taken = new Set(st.rooms.map((r) => r.name));
      let name = `Raum ${count}`;
      while (taken.has(name)) name = nextName(name, taken);
      const room = await post('/api/rooms', { floorId: floor.id, name, kind: 'room', capacity: 4, shape });
      st.rooms.push(room);
      syncGlobal(room);
      st.selectedId = room.id;
      saving(-1);
      setTool('select');
      renderPanel();
      const nameInput = panel.querySelector('input');
      nameInput?.focus();
      nameInput?.select();
    } catch (err) {
      saving(-1, true);
      toastError(err);
      draw();
    }
  }

  // ---------------------------------------------------------------- Tastatur
  const nudge = debounce((room) => saveRoom(room, { shape: room.shape }), 400);
  function onKey(e) {
    const tag = document.activeElement?.tagName;
    if (['INPUT', 'TEXTAREA', 'SELECT'].includes(tag) || document.querySelector('dialog[open]')) return;
    const room = selected();
    if (e.key === 'Escape') {
      if (st.drawing) st.drawing = null;
      else if (st.tool !== 'select') setTool('select');
      else st.selectedId = null;
      renderPanel();
      draw();
    } else if (e.key === 'Enter' && st.tool === 'poly' && st.drawing) {
      e.preventDefault();
      finishPolygon();
    } else if ((e.key === 'Delete' || e.key === 'Backspace') && room) {
      e.preventDefault();
      deleteRoom(room);
    } else if (e.key.startsWith('Arrow') && room?.shape) {
      e.preventDefault();
      const step = (st.grid ? st.gridSize : 1) * (e.shiftKey ? 5 : 1);
      const dx = e.key === 'ArrowLeft' ? -step : e.key === 'ArrowRight' ? step : 0;
      const dy = e.key === 'ArrowUp' ? -step : e.key === 'ArrowDown' ? step : 0;
      room.shape = moveShape(room.shape, dx, dy);
      draw();
      nudge(room);
    } else if (!e.ctrlKey && !e.metaKey && !e.altKey) {
      const map = { v: 'select', r: 'rect', p: 'poly' };
      if (map[e.key.toLowerCase()]) setTool(map[e.key.toLowerCase()]);
    }
  }
  document.addEventListener('keydown', onKey);

  // ---------------------------------------------------------------- Seitenleiste
  async function deleteRoom(room) {
    const ok = await confirmDialog(`„${room.name}“ löschen?`, {
      title: room.kind === 'area' ? 'Bereich löschen' : 'Raum löschen',
      confirmLabel: 'Löschen',
      danger: true,
      details: room.kind === 'area' ? null : 'Zukünftige Buchungen dieses Raums werden storniert und die Betroffenen benachrichtigt.',
    });
    if (!ok) return;
    try {
      const res = await del(`/api/rooms/${room.id}`);
      st.rooms = st.rooms.filter((r) => r.id !== room.id);
      state.layout.rooms = state.layout.rooms.filter((r) => r.id !== room.id);
      st.selectedId = null;
      toast(`„${room.name}“ gelöscht`, { type: 'success', body: res.cancelledBookings ? `${res.cancelledBookings} Buchungen storniert, Betroffene benachrichtigt.` : undefined });
      renderPanel();
      draw();
    } catch (err) {
      toastError(err);
    }
  }

  async function duplicateRoom(room) {
    const taken = new Set(st.rooms.map((r) => r.name));
    let shape = null;
    if (room.shape) {
      const bb = shapeBBox(room.shape);
      const gap = st.grid ? st.gridSize : 10;
      const dx = bb.x + bb.w * 2 + gap <= floor.width ? bb.w + gap : 0;
      const dy = dx ? 0 : bb.y + bb.h * 2 + gap <= floor.height ? bb.h + gap : gap * 2;
      shape = room.shape.type === 'rect' ? { ...room.shape, x: room.shape.x + dx, y: room.shape.y + dy } : { type: 'poly', points: room.shape.points.map(([x, y]) => [x + dx, y + dy]) };
    }
    saving(1);
    try {
      const copy = await post('/api/rooms', {
        floorId: floor.id,
        name: nextName(room.name, taken),
        kind: room.kind,
        capacity: room.capacity,
        equipment: room.equipment,
        description: room.description,
        bookable: room.bookable,
        shape,
      });
      st.rooms.push(copy);
      syncGlobal(copy);
      st.selectedId = copy.id;
      saving(-1);
      renderPanel();
      draw();
    } catch (err) {
      saving(-1, true);
      toastError(err);
    }
  }

  function roomForm(room) {
    const nameIn = h('input', { class: 'input', value: room.name, maxlength: 100 });
    const kindSel = h('select', { class: 'input' }, Object.entries(KIND_LABEL).map(([k, v]) => h('option', { value: k }, k === 'area' ? 'Bereich (nicht buchbar, z. B. Flur, Küche)' : v)));
    kindSel.value = room.kind;
    const capIn = h('input', { class: 'input', type: 'number', min: 0, max: 10000, value: room.capacity });
    const descIn = h('textarea', { class: 'input', rows: 2, maxlength: 2000, placeholder: 'Optional: Hinweise, Lage, Besonderheiten …' }, room.description);
    const bookIn = h('input', { type: 'checkbox', checked: room.bookable });
    const options = [...new Set([...(state.config.equipmentOptions || []), ...(room.equipment || [])])];
    const equipBoxes = options.map((eq) => {
      const cb = h('input', { type: 'checkbox', value: eq, checked: (room.equipment || []).includes(eq) });
      return { eq, cb, el: h('label', { class: 'check small' }, cb, eq) };
    });

    const save = (patch) => {
      Object.assign(room, patch);
      draw();
      return saveRoom(room, patch);
    };
    const saveText = debounce(() => {
      const name = nameIn.value.trim();
      if (!name) return;
      save({ name, description: descIn.value });
    }, 500);
    nameIn.addEventListener('input', () => {
      room.name = nameIn.value;
      draw();
      saveText();
    });
    descIn.addEventListener('input', saveText);
    kindSel.addEventListener('change', async () => {
      if (room.kind !== 'area' && kindSel.value === 'area') {
        const ok = await confirmDialog(`„${room.name}“ in einen nicht buchbaren Bereich umwandeln?`, { details: 'Zukünftige Buchungen werden storniert.', confirmLabel: 'Umwandeln' });
        if (!ok) {
          kindSel.value = room.kind;
          return;
        }
      }
      const patch = { kind: kindSel.value };
      if (kindSel.value === 'desk' && !room.capacity) patch.capacity = 1;
      await save(patch);
      renderPanel();
    });
    capIn.addEventListener('change', () => save({ capacity: Math.max(0, Number(capIn.value) || 0) }));
    bookIn.addEventListener('change', () => save({ bookable: bookIn.checked }));
    for (const { cb } of equipBoxes) {
      cb.addEventListener('change', () => save({ equipment: equipBoxes.filter((x) => x.cb.checked).map((x) => x.eq) }));
    }

    const shapeInfo = room.shape
      ? room.shape.type === 'rect'
        ? `Rechteck ${Math.round(room.shape.w)} × ${Math.round(room.shape.h)}`
        : `Polygon mit ${room.shape.points.length} Ecken`
      : 'Noch nicht im Plan eingezeichnet';

    return h(
      'div',
      { class: 'card-body form' },
      h('div', { class: 'field' }, h('label', null, 'Name'), nameIn),
      h('div', { class: 'field' }, h('label', null, 'Typ'), kindSel),
      room.kind === 'area'
        ? null
        : [
            h('div', { class: 'field' }, h('label', null, room.kind === 'desk' ? 'Plätze' : 'Kapazität (Personen)'), capIn),
            options.length ? h('div', { class: 'field' }, h('span', { class: 'label' }, 'Ausstattung'), h('div', { class: 'grid-2', style: { gap: '6px' } }, equipBoxes.map((x) => x.el))) : null,
            h('label', { class: 'check' }, bookIn, h('span', null, 'Buchbar', h('div', { class: 'hint' }, 'Abschalten, um den Raum vorübergehend zu sperren (bestehende Buchungen bleiben).'))),
          ],
      h('div', { class: 'field' }, h('label', null, 'Beschreibung'), descIn),
      h('div', { class: 'hint' }, `Form: ${shapeInfo}`),
      h(
        'div',
        { class: 'row' },
        h(
          'button',
          {
            class: 'btn btn-sm',
            type: 'button',
            onClick: () => {
              st.placingId = room.id;
              setTool('rect');
              toast(`Zeichne jetzt die Form für „${room.name}“.`, { type: 'info', timeout: 4000 });
            },
          },
          icon('square'),
          room.shape ? 'Neu zeichnen' : 'Einzeichnen',
        ),
        room.shape?.type === 'rect'
          ? h(
              'button',
              {
                class: 'btn btn-sm',
                type: 'button',
                title: 'Erlaubt freie Formen (z. B. L-förmige Räume): Punkte auf den Kanten ziehen fügt Ecken hinzu.',
                onClick: async () => {
                  const { x, y, w, h: hh } = room.shape;
                  await save({ shape: { type: 'poly', points: [[x, y], [x + w, y], [x + w, y + hh], [x, y + hh]] } });
                  renderPanel();
                },
              },
              icon('polygon'),
              'In Polygon umwandeln',
            )
          : null,
        h('button', { class: 'btn btn-sm', type: 'button', title: 'Kopie daneben anlegen – praktisch für Arbeitsplatzreihen', onClick: () => duplicateRoom(room) }, icon('copy'), 'Duplizieren'),
        h('button', { class: 'btn btn-sm btn-danger', type: 'button', onClick: () => deleteRoom(room) }, icon('trash'), 'Löschen'),
      ),
    );
  }

  function renderPanel() {
    const room = selected();
    if (room) {
      panel.replaceChildren(
        h(
          'div',
          { class: 'card-head' },
          h('h2', null, room.kind === 'area' ? 'Bereich' : KIND_LABEL[room.kind]),
          h('button', { class: 'btn btn-ghost btn-sm', type: 'button', onClick: () => ((st.selectedId = null), renderPanel(), draw()) }, 'Fertig'),
        ),
        roomForm(room),
      );
      return;
    }
    const list = [...st.rooms].sort((a, b) => a.name.localeCompare(b.name, 'de', { numeric: true }));
    panel.replaceChildren(
      h('div', { class: 'card-head' }, h('h2', null, 'Räume dieser Etage'), h('span', { class: 'badge' }, String(list.length))),
      h(
        'div',
        { class: 'card-body stack-sm' },
        h('p', { class: 'small muted' }, 'So geht’s: ', h('strong', null, '1.'), ' Grundriss hochladen (optional) · ', h('strong', null, '2.'), ' Mit „Rechteck“ oder „Polygon“ Räume einzeichnen · ', h('strong', null, '3.'), ' Name, Kapazität und Ausstattung festlegen. Alles wird automatisch gespeichert.'),
        h('p', { class: 'small muted' }, 'Tastatur: ', h('span', { class: 'kbd' }, 'V'), ' Auswählen · ', h('span', { class: 'kbd' }, 'R'), ' Rechteck · ', h('span', { class: 'kbd' }, 'P'), ' Polygon · ', h('span', { class: 'kbd' }, 'Entf'), ' Löschen · Pfeiltasten verschieben'),
      ),
      list.length
        ? h(
            'div',
            { style: { paddingBottom: '8px' } },
            list.map((r) =>
              h(
                'div',
                {
                  class: 'room-list-item',
                  role: 'button',
                  tabindex: '0',
                  onClick: () => {
                    st.selectedId = r.id;
                    if (!r.shape) {
                      st.placingId = r.id;
                      setTool('rect');
                    }
                    renderPanel();
                    draw();
                  },
                },
                h('span', { class: `kind-dot ${r.kind}` }),
                h('span', { style: { flex: '1', minWidth: '0' } }, r.name),
                r.shape ? h('span', { class: 'muted small' }, r.kind === 'area' ? 'Bereich' : r.capacity ? `${r.capacity} P.` : '') : h('span', { class: 'badge soon' }, 'nicht platziert'),
              ),
            ),
          )
        : h('div', { class: 'card-body' }, emptyState('square', 'Noch keine Räume', 'Wähle „Rechteck“ und ziehe im Plan einen Raum auf.')),
    );
  }

  setTool('select');
  renderPanel();
  const onResize = debounce(draw, 150);
  window.addEventListener('resize', onResize);
  requestAnimationFrame(draw);
  return () => {
    document.removeEventListener('keydown', onKey);
    window.removeEventListener('resize', onResize);
  };
}
