import fs from 'node:fs';
import path from 'node:path';
import { Sessions } from './auth.js';
import { BackupService } from './backup.js';
import { BookingService } from './bookings.js';
import { openDatabase } from './db.js';
import { EventHub } from './events.js';
import { LayoutService } from './layout.js';
import { Mailer } from './mailer.js';
import { Notifier } from './notifier.js';
import { ReminderService } from './reminders.js';
import { Settings } from './settings.js';
import { UserService } from './users.js';
import { WatchService } from './watches.js';

export const consoleLog = {
  info: (...a) => console.log(new Date().toISOString(), ...a),
  warn: (...a) => console.warn(new Date().toISOString(), ...a),
  error: (...a) => console.error(new Date().toISOString(), ...a),
};

/** Baut alle Dienste zusammen. `clock` und `transport` lassen sich für Tests austauschen. */
export function createContext(config, { clock = { now: () => Date.now() }, transport, log = consoleLog } = {}) {
  fs.mkdirSync(config.dataDir, { recursive: true });
  const dbFile = config.dbFile || path.join(config.dataDir, 'raumplaner.db');
  const db = openDatabase(dbFile, { onAfterCommitError: (err) => log.error('[db] Fehler nach COMMIT:', err) });

  const ctx = { config, clock, log, db, dbFile, startedAt: Date.now() };
  ctx.audit = (userId, action, details = '') => {
    db.run('INSERT INTO audit_log (user_id, action, details, created_at) VALUES (?, ?, ?, ?)', [userId ?? null, action, details, clock.now()]);
  };
  ctx.settings = new Settings(ctx);
  ctx.hub = new EventHub();
  ctx.mailer = new Mailer({ db, config, log, clock, transport });
  ctx.notifier = new Notifier({ db, hub: ctx.hub, mailer: ctx.mailer, config, clock, settings: ctx.settings });
  ctx.sessions = new Sessions({ db, config, clock });
  ctx.bookings = new BookingService(ctx);
  ctx.watches = new WatchService(ctx);
  ctx.layout = new LayoutService(ctx);
  ctx.users = new UserService(ctx);
  ctx.reminders = new ReminderService(ctx);
  ctx.backups = new BackupService(ctx);
  return ctx;
}

/** Startet die Hintergrundprozesse (Mailversand, Erinnerungen, Backups, Aufräumen). */
export function startBackground(ctx) {
  ctx.hub.start();
  ctx.mailer.start();
  ctx.reminders.start();
  ctx.backups.start();
  const housekeeping = () => {
    try {
      ctx.sessions.purgeExpired();
      ctx.watches.purgeExpired();
      const cutoff = ctx.clock.now() - 180 * 86400000;
      ctx.db.run('DELETE FROM notifications WHERE created_at < ?', [cutoff]);
      ctx.db.run(`DELETE FROM email_outbox WHERE status = 'sent' AND created_at < ?`, [cutoff]);
      ctx.db.run('DELETE FROM audit_log WHERE created_at < ?', [ctx.clock.now() - 730 * 86400000]);
    } catch (err) {
      ctx.log.error('[wartung] Fehler:', err);
    }
  };
  housekeeping();
  ctx.housekeepingTimer = setInterval(housekeeping, 6 * 3600000);
  ctx.housekeepingTimer.unref?.();
}

export function stopBackground(ctx) {
  clearInterval(ctx.housekeepingTimer);
  ctx.reminders.stop();
  ctx.mailer.stop();
  ctx.backups.stop();
  ctx.hub.stop();
}
