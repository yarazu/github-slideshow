import { createApp } from './app.js';
import { loadConfig } from './config.js';
import { consoleLog as log, createContext, startBackground, stopBackground } from './context.js';

const config = loadConfig();
const ctx = createContext(config, { log });
const app = createApp(ctx);

const server = app.listen(config.port, config.host, () => {
  log.info(`Raumplaner ${config.version} läuft auf ${config.publicUrl} (Port ${config.port}, Zeitzone ${config.timezone})`);
  log.info(`Daten: ${ctx.dbFile}`);
  if (ctx.mailer.mode === 'disabled') {
    log.warn('E-Mail-Versand ist nicht eingerichtet (SMTP_HOST fehlt) – In-App- und Live-Benachrichtigungen funktionieren trotzdem.');
  } else if (ctx.mailer.mode === 'log') {
    log.info('E-Mails werden nur protokolliert (MAIL_LOG_ONLY=true).');
  } else {
    log.info(`E-Mail-Versand über ${ctx.mailer.smtpLabel}`);
  }
  if (ctx.users.count() === 0) log.info(`Ersteinrichtung: Öffne ${config.publicUrl} und lege das erste Administrator-Konto an.`);
});
server.keepAliveTimeout = 65000;
startBackground(ctx);

let stopping = false;
function shutdown(signal) {
  if (stopping) return;
  stopping = true;
  log.info(`${signal} empfangen – fahre geordnet herunter …`);
  stopBackground(ctx);
  server.close(() => {
    ctx.db.close();
    log.info('Beendet.');
    process.exit(0);
  });
  setTimeout(() => {
    log.warn('Herunterfahren dauert zu lange – beende hart.');
    process.exit(1);
  }, 10000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('unhandledRejection', (err) => log.error('Unbehandelter Fehler (Promise):', err));
process.on('uncaughtException', (err) => {
  log.error('Unbehandelter Fehler:', err);
  shutdown('uncaughtException');
});
