import fs from 'node:fs';
import path from 'node:path';

const NAME_RE = /^raumplaner-\d{8}-\d{6}(-\d+)?\.db$/;

/**
 * Automatische Datensicherung: Kopiert die komplette Datenbank (inkl. Grundrisse) in
 * data/backups/. Die Kopie ist in sich konsistent (SQLite „VACUUM INTO“) und kann zur
 * Wiederherstellung einfach an die Stelle der Datenbankdatei kopiert werden.
 */
export class BackupService {
  constructor(ctx) {
    this.ctx = ctx;
    this.dir = path.join(ctx.config.dataDir, 'backups');
    this.timer = null;
  }

  start() {
    const hours = this.ctx.config.backupIntervalHours;
    if (!hours || hours <= 0) return;
    const check = () => {
      try {
        const latest = this.list()[0];
        if (!latest || Date.now() - latest.createdAt >= hours * 3600000) this.backupNow('automatisch');
      } catch (err) {
        this.ctx.log.error('[backup] Fehler:', err);
      }
    };
    check();
    this.timer = setInterval(check, 3600000);
    this.timer.unref?.();
  }

  stop() {
    clearInterval(this.timer);
    this.timer = null;
  }

  backupNow(reason = 'manuell') {
    fs.mkdirSync(this.dir, { recursive: true });
    const d = new Date();
    const stamp = `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
    let name = `raumplaner-${stamp}.db`;
    for (let i = 2; fs.existsSync(path.join(this.dir, name)); i++) name = `raumplaner-${stamp}-${i}.db`;
    const file = path.join(this.dir, name);
    this.ctx.db.run('VACUUM INTO ?', [file]);
    const size = fs.statSync(file).size;
    this.prune();
    this.ctx.log.info(`[backup] Sicherung erstellt (${reason}): ${file} (${Math.round(size / 1024)} KB)`);
    return { name, size, createdAt: Date.now() };
  }

  list() {
    if (!fs.existsSync(this.dir)) return [];
    return fs
      .readdirSync(this.dir)
      .filter((n) => NAME_RE.test(n))
      .map((name) => {
        const st = fs.statSync(path.join(this.dir, name));
        return { name, size: st.size, createdAt: st.mtimeMs };
      })
      .sort((a, b) => b.createdAt - a.createdAt || b.name.localeCompare(a.name));
  }

  prune() {
    const keep = Math.max(1, this.ctx.config.backupKeep);
    for (const old of this.list().slice(keep)) {
      fs.rmSync(path.join(this.dir, old.name), { force: true });
    }
  }
}

function pad(n) {
  return String(n).padStart(2, '0');
}
