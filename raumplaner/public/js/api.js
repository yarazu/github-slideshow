/** Kleiner Event-Bus für App-weite Ereignisse (Live-Updates, Layout-Änderungen …). */
const target = new EventTarget();
export const bus = {
  on(type, fn) {
    const handler = (e) => fn(e.detail);
    target.addEventListener(type, handler);
    return () => target.removeEventListener(type, handler);
  },
  emit(type, detail) {
    target.dispatchEvent(new CustomEvent(type, { detail }));
  },
};

export class ApiError extends Error {
  constructor(status, body) {
    super(body?.message || `Fehler ${status}`);
    this.status = status;
    this.body = body || {};
  }
}

/** fetch-Hülle: setzt den CSRF-Header, wandelt Fehler in verständliche Meldungen um. */
export async function api(method, url, body, { raw = false, headers = {} } = {}) {
  const opts = {
    method,
    credentials: 'same-origin',
    headers: { 'X-Requested-With': 'raumplaner', Accept: 'application/json', ...headers },
  };
  if (body !== undefined) {
    if (raw) opts.body = body;
    else {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(body);
    }
  }
  let res;
  try {
    res = await fetch(url, opts);
  } catch {
    throw new ApiError(0, { message: 'Keine Verbindung zum Server. Bitte prüfe deine Netzwerkverbindung und versuche es erneut.' });
  }
  const isJson = (res.headers.get('content-type') || '').includes('application/json');
  const data = isJson ? await res.json().catch(() => null) : null;
  if (!res.ok) {
    if (res.status === 401 && !url.startsWith('/api/auth') && !url.startsWith('/api/setup')) bus.emit('unauthorized');
    throw new ApiError(res.status, data || { message: `Fehler ${res.status}` });
  }
  return data;
}

export const get = (url) => api('GET', url);
export const post = (url, body = {}) => api('POST', url, body);
export const put = (url, body = {}) => api('PUT', url, body);
export const del = (url) => api('DELETE', url);

export function qs(params) {
  const sp = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== null && v !== '') sp.set(k, v);
  return sp.toString();
}
