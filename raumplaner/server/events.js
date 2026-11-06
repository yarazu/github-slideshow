/**
 * Live-Verbindungen zu den Browsern (Server-Sent Events).
 * Darüber erfahren geöffnete Tabs sofort von neuen Benachrichtigungen und Belegungsänderungen.
 * Geht eine Verbindung verloren, verbindet sich der Browser automatisch neu und lädt den
 * aktuellen Stand nach – es geht also nichts verloren (die Daten liegen in der Datenbank).
 */
export class EventHub {
  constructor() {
    this.clients = new Map();
    this.timer = null;
  }

  start() {
    this.timer = setInterval(() => this.ping(), 25000);
    this.timer.unref?.();
  }

  stop() {
    clearInterval(this.timer);
    for (const set of this.clients.values()) {
      for (const res of set) res.end();
    }
    this.clients.clear();
  }

  attach(req, res, userId, hello) {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    });
    res.write('retry: 5000\n\n');
    let set = this.clients.get(userId);
    if (!set) {
      set = new Set();
      this.clients.set(userId, set);
    }
    set.add(res);
    if (hello) res.write(format('hello', hello));
    req.on('close', () => {
      set.delete(res);
      if (!set.size) this.clients.delete(userId);
    });
  }

  sendToUser(userId, event, data) {
    const set = this.clients.get(userId);
    if (!set) return;
    const msg = format(event, data);
    for (const res of set) res.write(msg);
  }

  broadcast(event, data) {
    const msg = format(event, data);
    for (const set of this.clients.values()) {
      for (const res of set) res.write(msg);
    }
  }

  ping() {
    for (const set of this.clients.values()) {
      for (const res of set) res.write(': ping\n\n');
    }
  }

  get connectionCount() {
    let n = 0;
    for (const set of this.clients.values()) n += set.size;
    return n;
  }
}

function format(event, data) {
  return `event: ${event}\ndata: ${JSON.stringify(data ?? {})}\n\n`;
}
