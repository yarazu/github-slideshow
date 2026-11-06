/**
 * NUR FÜR LOKALE TESTS: bildet die claude.ai-Laufzeit (window.claude.use) nach,
 * damit die Web-Version ohne claude.ai im Browser getestet werden kann.
 *
 * - db: Dokumente in localStorage, Live-Abos über BroadcastChannel (mehrere Tabs = mehrere Personen),
 *   Leases (acquire) mit Ablaufzeit, künstliche Netzwerk-Latenz.
 * - user: ?user=anna (Besitzerin), ?user=ben (Mitarbeiter), ?user=cara (nur ansehen)
 * - assets: Upload an den Test-Server (/_blob), downloads: werden in window.__downloads protokolliert.
 */
(() => {
  const PEOPLE = {
    anna: { id: 'u_anna', name: 'Anna Admin', email: 'anna@muster.de', owner: true },
    ben: { id: 'u_ben', name: 'Ben Bauer', email: 'ben@muster.de' },
    cara: { id: 'u_cara', name: 'Cara Klein', email: 'cara@muster.de', viewOnly: true },
  };
  const who = new URLSearchParams(location.search).get('user') || 'anna';
  const meP = PEOPLE[who] || PEOPLE.anna;
  const KEY = 'mockdb:v1';
  const channel = new BroadcastChannel('mockdb');
  const listeners = new Set();
  const latency = () => new Promise((r) => setTimeout(r, 15 + Math.random() * 35));
  const load = () => {
    try {
      return JSON.parse(localStorage.getItem(KEY) || '{}');
    } catch {
      return {};
    }
  };
  const save = (data) => localStorage.setItem(KEY, JSON.stringify(data));
  const fanOut = () => setTimeout(() => listeners.forEach((l) => l()), 0);
  channel.onmessage = fanOut;
  const changed = () => {
    channel.postMessage('changed');
    fanOut();
  };
  const segs = (p) => p.split('/');
  let counter = 0;
  const newId = () => `m${Date.now().toString(36)}${(counter++).toString(36)}${Math.random().toString(36).slice(2, 7)}`;
  const copy = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));
  window.__dbWrites = 0;

  function deny(path) {
    if (meP.viewOnly) throw { code: 'invalid_argument', message: `Schreiben verboten: ${path}` };
    if (path.startsWith('data/users/') && segs(path)[2] !== meP.id) throw { code: 'invalid_argument', message: 'fremder Bereich' };
    if (/^(layout|settings)\//.test(path) && !meP.owner) throw { code: 'invalid_argument', message: 'nur admin' };
    if (path.startsWith('people/') && segs(path)[1] !== meP.id && !meP.owner) throw { code: 'invalid_argument', message: 'nur eigenes people-Dokument' };
  }

  function merge(target, patch) {
    const out = { ...target };
    for (const [k, v] of Object.entries(patch)) {
      out[k] = v && typeof v === 'object' && !Array.isArray(v) && out[k] && typeof out[k] === 'object' && !Array.isArray(out[k]) ? merge(out[k], v) : v;
    }
    return out;
  }

  const meta = { fromCache: false, hasPendingWrites: false };
  const docSnap = (path, data) => ({ id: segs(path).pop(), exists: data !== undefined, data: () => copy(data), metadata: meta });

  function docRef(path) {
    if (segs(path).length % 2) throw new TypeError(`Dokumentpfad braucht eine gerade Anzahl Segmente: ${path}`);
    return {
      id: segs(path).pop(),
      path,
      async get() {
        await latency();
        return docSnap(path, load()[path]);
      },
      async set(data) {
        await latency();
        deny(path);
        const d = load();
        d[path] = copy(data);
        save(d);
        window.__dbWrites += 1;
        changed();
      },
      async update(data) {
        await latency();
        deny(path);
        const d = load();
        if (!d[path]) throw { code: 'invalid_argument', message: `update auf fehlendes Dokument ${path}` };
        d[path] = merge(d[path], copy(data));
        save(d);
        window.__dbWrites += 1;
        changed();
      },
      async delete() {
        await latency();
        deny(path);
        const d = load();
        delete d[path];
        save(d);
        changed();
      },
      async acquire({ holder, ttlMs = 30000 }) {
        await latency();
        deny(path);
        const key = `mocklease:${path}`;
        const now = Date.now();
        let cur = null;
        try {
          cur = JSON.parse(localStorage.getItem(key));
        } catch {
          cur = null;
        }
        if (cur && cur.expiresAt > now && cur.holder !== holder) return { acquired: false, expiresAt: new Date(cur.expiresAt).toISOString() };
        const ttl = Math.min(Math.max(ttlMs || 30000, 1000), 600000);
        localStorage.setItem(key, JSON.stringify({ holder, expiresAt: now + ttl }));
        return { acquired: true, version: 1, expiresAt: new Date(now + ttl).toISOString(), holder };
      },
      onSnapshot(next) {
        let last;
        const run = () => {
          const data = load()[path];
          const json = JSON.stringify(data);
          if (json === last) return;
          last = json;
          next(docSnap(path, data));
        };
        listeners.add(run);
        setTimeout(run, 20);
        return () => listeners.delete(run);
      },
      collection: (sub) => collRef(`${path}/${sub}`),
    };
  }

  function compare(a, op, b) {
    switch (op) {
      case '==':
        return a === b;
      case '!=':
        return a !== undefined && a !== b;
      case '<':
        return a !== undefined && a !== null && a < b;
      case '<=':
        return a !== undefined && a !== null && a <= b;
      case '>':
        return a !== undefined && a !== null && a > b;
      case '>=':
        return a !== undefined && a !== null && a >= b;
      case 'in':
        return b.includes(a);
      case 'not-in':
        return !b.includes(a);
      case 'array-contains':
        return Array.isArray(a) && a.includes(b);
      default:
        throw { code: 'invalid_argument', message: `Operator ${op}` };
    }
  }

  function querySnap(rows, prev) {
    const docs = rows.map((r) => docSnap(r.path, r.data));
    const before = new Map((prev || []).map((r) => [r.id, JSON.stringify(r.data)]));
    const changes = [];
    rows.forEach((r, i) => {
      if (!before.has(r.id)) changes.push({ type: 'added', doc: docs[i], oldIndex: -1, newIndex: i });
      else if (before.get(r.id) !== JSON.stringify(r.data)) changes.push({ type: 'modified', doc: docs[i], oldIndex: i, newIndex: i });
    });
    for (const r of prev || []) if (!rows.some((x) => x.id === r.id)) changes.push({ type: 'removed', doc: docSnap(r.path, r.data), oldIndex: 0, newIndex: -1 });
    return { docs, size: docs.length, empty: !docs.length, docChanges: () => changes, metadata: meta };
  }

  function collRef(path, filters = [], order = null, lim = null) {
    if (segs(path).length % 2 === 0) throw new TypeError(`Sammlungspfad braucht eine ungerade Anzahl Segmente: ${path}`);
    const matches = () => {
      const prefix = `${path}/`;
      let rows = Object.entries(load())
        .filter(([p]) => p.startsWith(prefix) && !p.slice(prefix.length).includes('/'))
        .map(([p, data]) => ({ id: p.slice(prefix.length), path: p, data }));
      for (const [f, op, v] of filters) rows = rows.filter((r) => compare(r.data[f], op, v));
      if (order) {
        const [f, dir] = order;
        rows.sort((a, b) => {
          const x = a.data[f];
          const y = b.data[f];
          const c = x === y ? 0 : x === undefined ? 1 : y === undefined ? -1 : x < y ? -1 : 1;
          return dir === 'desc' ? -c : c;
        });
      } else rows.sort((a, b) => (a.id < b.id ? -1 : 1));
      if (lim) rows = rows.slice(0, lim);
      return rows;
    };
    return {
      path,
      where: (f, op, v) => {
        if (filters.length >= 10) throw { code: 'invalid_argument', message: 'zu viele Filter' };
        return collRef(path, [...filters, [f, op, v]], order, lim);
      },
      orderBy: (f, dir = 'asc') => collRef(path, filters, [f, dir], lim),
      limit: (n) => collRef(path, filters, order, n),
      async get() {
        await latency();
        return querySnap(matches(), null);
      },
      onSnapshot(next) {
        let prev = null;
        let prevJson = null;
        const run = () => {
          const rows = matches();
          const json = JSON.stringify(rows);
          if (json === prevJson) return;
          const snap = querySnap(rows, prev);
          prev = rows;
          prevJson = json;
          next(snap);
        };
        listeners.add(run);
        setTimeout(run, 20);
        return () => listeners.delete(run);
      },
      doc: (id) => docRef(`${path}/${id || newId()}`),
      async add(data) {
        const ref = docRef(`${path}/${newId()}`);
        await ref.set(data);
        return ref;
      },
    };
  }

  const db = Object.freeze({ doc: docRef, collection: (p) => collRef(p) });
  const profile = (p, id) => ({ id, name: p?.name || '', email: p?.email || null, avatarUrl: '', color: '#6b7280', isMe: id === meP.id, guest: false });
  const user = Object.freeze({
    isOwner: async () => Boolean(meP.owner),
    canEdit: async () => Boolean(meP.owner),
    can: async (name) => (name === 'data.write' ? !meP.viewOnly : Boolean(meP.owner)),
    me: async () => ({ ...profile(meP, meP.id), isOwner: Boolean(meP.owner), canEdit: Boolean(meP.owner) }),
    id: async () => meP.id,
    profiles: async (ids) => Object.fromEntries([].concat(ids).map((id) => [id, profile(Object.values(PEOPLE).find((x) => x.id === id), id)])),
    search: async (q) =>
      Object.values(PEOPLE)
        .filter((p) => !q || p.name.toLowerCase().includes(q.toLowerCase()))
        .slice(0, 8)
        .map((p) => profile(p, p.id)),
  });
  const assets = Object.freeze({
    async upload(blob, options = {}) {
      const type = options.type || blob.type;
      const res = await fetch('/_blob', { method: 'POST', headers: { 'Content-Type': type }, body: blob });
      const { id } = await res.json();
      return { id, url: `/_blob/${id}`, sizeBytes: blob.size, contentType: type };
    },
    async list() {
      return { assets: [], usage: { files: 1, bytes: 1000, maxFiles: 500, maxBytes: 1073741824 } };
    },
    async delete() {
      return { deleted: true };
    },
  });
  window.__downloads = [];
  const downloads = Object.freeze({
    async save({ filename, data }) {
      window.__downloads.push({ filename, size: typeof data === 'string' ? data.length : data.size || 0 });
      return { status: 'saved' };
    },
  });
  const namespaces = { db, user, assets: meP.owner ? assets : null, downloads };
  window.claude = Object.freeze({
    use: (name) => new Promise((resolve) => setTimeout(() => resolve(namespaces[name] ?? null), 30)),
  });
})();
