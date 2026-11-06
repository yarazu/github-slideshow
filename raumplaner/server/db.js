import { DatabaseSync } from 'node:sqlite';
import { MIGRATIONS } from './schema.js';

function normalize(value) {
  if (value === undefined) return null;
  if (typeof value === 'boolean') return value ? 1 : 0;
  return value;
}

function bindAndCall(stmt, method, params) {
  if (params === undefined) return stmt[method]();
  if (Array.isArray(params)) return stmt[method](...params.map(normalize));
  if (params && typeof params === 'object' && !ArrayBuffer.isView(params)) {
    const named = {};
    for (const [k, v] of Object.entries(params)) named[k] = normalize(v);
    return stmt[method](named);
  }
  return stmt[method](normalize(params));
}

/**
 * Schlanke, synchrone Hülle um node:sqlite.
 * - Prepared Statements werden zwischengespeichert.
 * - tx() führt eine Funktion atomar aus (BEGIN IMMEDIATE / SAVEPOINT bei Verschachtelung).
 * - afterCommit() verschiebt Seiteneffekte (Live-Events, Mailversand) bis nach dem COMMIT;
 *   bei einem ROLLBACK werden sie verworfen. So wird nie über etwas benachrichtigt,
 *   das gar nicht gespeichert wurde.
 */
export class Db {
  constructor(raw, { onAfterCommitError } = {}) {
    this.raw = raw;
    this.cache = new Map();
    this.depth = 0;
    this.pending = [];
    this.onAfterCommitError = onAfterCommitError || ((err) => console.error('[db] afterCommit-Fehler:', err));
  }

  stmt(sql) {
    let s = this.cache.get(sql);
    if (!s) {
      s = this.raw.prepare(sql);
      this.cache.set(sql, s);
    }
    return s;
  }

  get(sql, params) {
    return bindAndCall(this.stmt(sql), 'get', params);
  }

  all(sql, params) {
    return bindAndCall(this.stmt(sql), 'all', params);
  }

  run(sql, params) {
    const r = bindAndCall(this.stmt(sql), 'run', params);
    return { changes: Number(r.changes), lastInsertRowid: Number(r.lastInsertRowid) };
  }

  exec(sql) {
    this.raw.exec(sql);
  }

  get inTransaction() {
    return this.depth > 0;
  }

  tx(fn) {
    if (this.depth === 0) {
      this.raw.exec('BEGIN IMMEDIATE');
      this.depth = 1;
      let result;
      try {
        result = fn();
        if (result && typeof result.then === 'function') {
          throw new Error('db.tx() erwartet eine synchrone Funktion');
        }
        this.raw.exec('COMMIT');
      } catch (err) {
        try {
          this.raw.exec('ROLLBACK');
        } catch {
          /* Transaktion war bereits beendet */
        }
        this.pending = [];
        throw err;
      } finally {
        this.depth = 0;
      }
      const callbacks = this.pending;
      this.pending = [];
      for (const cb of callbacks) {
        try {
          cb();
        } catch (err) {
          this.onAfterCommitError(err);
        }
      }
      return result;
    }

    const name = `sp_${this.depth}`;
    const mark = this.pending.length;
    this.raw.exec(`SAVEPOINT ${name}`);
    this.depth += 1;
    try {
      const result = fn();
      this.raw.exec(`RELEASE ${name}`);
      return result;
    } catch (err) {
      this.raw.exec(`ROLLBACK TO ${name}`);
      this.raw.exec(`RELEASE ${name}`);
      this.pending.length = mark;
      throw err;
    } finally {
      this.depth -= 1;
    }
  }

  /** Führt cb nach erfolgreichem COMMIT aus (oder sofort, wenn keine Transaktion läuft). */
  afterCommit(cb) {
    if (this.depth > 0) this.pending.push(cb);
    else {
      try {
        cb();
      } catch (err) {
        this.onAfterCommitError(err);
      }
    }
  }

  migrate(migrations) {
    const current = this.raw.prepare('PRAGMA user_version').get().user_version;
    for (let v = current; v < migrations.length; v++) {
      this.tx(() => {
        this.raw.exec(migrations[v]);
        this.raw.exec(`PRAGMA user_version = ${v + 1}`);
      });
    }
    return migrations.length;
  }

  close() {
    this.cache.clear();
    this.raw.close();
  }
}

export function openDatabase(file, options) {
  const raw = new DatabaseSync(file);
  raw.exec('PRAGMA journal_mode = WAL');
  raw.exec('PRAGMA foreign_keys = ON');
  raw.exec('PRAGMA busy_timeout = 5000');
  raw.exec('PRAGMA synchronous = NORMAL');
  const db = new Db(raw, options);
  db.migrate(MIGRATIONS);
  return db;
}
