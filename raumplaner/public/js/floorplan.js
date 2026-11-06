import { s } from './ui.js';

/** Hilfsfunktionen für Raumformen (Rechteck oder Polygon in Plan-Koordinaten). */
export function shapeBBox(shape) {
  if (shape.type === 'rect') return { x: shape.x, y: shape.y, w: shape.w, h: shape.h };
  const xs = shape.points.map((p) => p[0]);
  const ys = shape.points.map((p) => p[1]);
  const x = Math.min(...xs);
  const y = Math.min(...ys);
  return { x, y, w: Math.max(...xs) - x, h: Math.max(...ys) - y };
}

export function shapeCenter(shape) {
  if (shape.type === 'rect') return [shape.x + shape.w / 2, shape.y + shape.h / 2];
  const pts = shape.points;
  let area = 0;
  let cx = 0;
  let cy = 0;
  for (let i = 0; i < pts.length; i++) {
    const [x0, y0] = pts[i];
    const [x1, y1] = pts[(i + 1) % pts.length];
    const f = x0 * y1 - x1 * y0;
    area += f;
    cx += (x0 + x1) * f;
    cy += (y0 + y1) * f;
  }
  if (Math.abs(area) < 1e-6) {
    const b = shapeBBox(shape);
    return [b.x + b.w / 2, b.y + b.h / 2];
  }
  area *= 0.5;
  return [cx / (6 * area), cy / (6 * area)];
}

export function shapeElement(shape, attrs = {}) {
  if (shape.type === 'rect') {
    return s('rect', { x: shape.x, y: shape.y, width: shape.w, height: shape.h, rx: 4, ...attrs });
  }
  return s('polygon', { points: shape.points.map((p) => p.join(',')).join(' '), ...attrs });
}

export function planDefs(gridSize = 50) {
  return s(
    'defs',
    null,
    s(
      'pattern',
      { id: 'hatch', width: 10, height: 10, patternUnits: 'userSpaceOnUse', patternTransform: 'rotate(45)' },
      s('rect', { width: 10, height: 10, class: 'hatch-bg' }),
      s('line', { x1: 0, y1: 0, x2: 0, y2: 10, class: 'hatch-line' }),
    ),
    s(
      'pattern',
      { id: 'plan-grid', width: gridSize, height: gridSize, patternUnits: 'userSpaceOnUse' },
      s('path', { d: `M ${gridSize} 0 L 0 0 0 ${gridSize}`, fill: 'none', class: 'plan-grid-line', 'stroke-width': 1 }),
    ),
  );
}

/** Grundrisshintergrund: hochgeladenes Bild oder ein dezentes Raster. */
export function planBackground(floor, { grid = true } = {}) {
  const items = [s('rect', { x: 0, y: 0, width: floor.width, height: floor.height, class: 'plan-bg-rect' })];
  if (floor.imageUrl) {
    items.push(s('image', { href: floor.imageUrl, x: 0, y: 0, width: floor.width, height: floor.height, preserveAspectRatio: 'xMidYMid meet' }));
  } else if (grid) {
    items.push(s('rect', { x: 0, y: 0, width: floor.width, height: floor.height, fill: 'url(#plan-grid)' }));
  }
  return items;
}

/** Beschriftung, die sich der Raumgröße anpasst. */
export function roomLabel(shape, lines, base) {
  const [cx, cy] = shapeCenter(shape);
  const bb = shapeBBox(shape);
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(v, hi));
  // Name und Zusatzzeile werden getrennt eingepasst, damit ein langer Status den Namen nicht verkleinert.
  const main = lines.find((l) => !l.sub) || lines[0];
  const mainSize = clamp(Math.min(bb.h / (lines.length * 1.35 + 0.6), bb.w / (Math.max(main.text.length, 3) * 0.62)), base * 0.55, base * 1.25);
  const sizeOf = (l) => (l.sub ? clamp(Math.min(mainSize * 0.82, bb.w / (Math.max(l.text.length, 3) * 0.56)), base * 0.42, base) : mainSize);
  const total = lines.reduce((acc, l) => acc + sizeOf(l) * 1.2, 0);
  let y = cy - total / 2;
  return lines.map((l) => {
    const fs = sizeOf(l);
    y += fs * 1.2;
    return s(
      'text',
      { x: cx, y: y - fs * 0.25, 'text-anchor': 'middle', class: l.sub ? 'room-sub' : 'room-label', 'font-size': fs.toFixed(1) },
      l.text,
    );
  });
}

/**
 * Lageplan (Ansicht) rendern.
 * @param {object} floor
 * @param {object[]} rooms
 * @param {{status:(room)=>string, lines:(room,status)=>{text:string,sub?:boolean}[], selectedId?:number,
 *          onSelect?:(room)=>void, aria?:(room,status)=>string}} opts
 */
export function renderPlan(floor, rooms, { status, lines, selectedId, onSelect, aria } = {}) {
  const svg = s('svg', {
    class: floor.imageUrl ? 'plan has-image' : 'plan',
    viewBox: `0 0 ${floor.width} ${floor.height}`,
    role: 'group',
    'aria-label': `Lageplan ${floor.name}`,
  });
  svg.append(planDefs(), ...planBackground(floor));
  const base = Math.max(floor.width, floor.height) / 55;
  const placed = rooms.filter((r) => r.shape).sort((a, b) => (a.kind === 'area' ? 0 : 1) - (b.kind === 'area' ? 0 : 1));
  for (const room of placed) {
    const st = room.kind === 'area' ? 'area' : status(room);
    const g = s('g', { class: `room ${st}${room.id === selectedId ? ' selected' : ''}`, 'data-room-id': room.id });
    g.append(shapeElement(room.shape, { class: 'room-shape' }));
    g.append(...roomLabel(room.shape, lines(room, st), base));
    if (room.kind !== 'area' && onSelect) {
      g.setAttribute('tabindex', '0');
      g.setAttribute('role', 'button');
      g.setAttribute('aria-label', aria ? aria(room, st) : room.name);
      g.addEventListener('click', () => onSelect(room));
      g.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          onSelect(room);
        }
      });
    }
    svg.append(g);
  }
  return svg;
}
