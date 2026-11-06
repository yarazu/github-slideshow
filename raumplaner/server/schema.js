/**
 * Datenbank-Migrationen. Jede Migration läuft genau einmal (gesteuert über PRAGMA user_version).
 * Neue Änderungen immer als NEUEN Eintrag anhängen – bestehende Einträge nie verändern.
 */
export const MIGRATIONS = [
  /* 1: Grundschema */ `
  CREATE TABLE users (
    id               INTEGER PRIMARY KEY,
    email            TEXT    NOT NULL COLLATE NOCASE UNIQUE,
    name             TEXT    NOT NULL,
    password_hash    TEXT    NOT NULL,
    role             TEXT    NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'admin')),
    active           INTEGER NOT NULL DEFAULT 1,
    notify_email     INTEGER NOT NULL DEFAULT 1,
    reminder_minutes INTEGER NOT NULL DEFAULT 15,
    calendar_token   TEXT    NOT NULL UNIQUE,
    created_at       INTEGER NOT NULL,
    last_login_at    INTEGER
  );

  CREATE TABLE sessions (
    token_hash TEXT    PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
  );
  CREATE INDEX sessions_user ON sessions(user_id);

  CREATE TABLE buildings (
    id         INTEGER PRIMARY KEY,
    name       TEXT    NOT NULL,
    address    TEXT    NOT NULL DEFAULT '',
    sort       INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL
  );

  CREATE TABLE floors (
    id            INTEGER PRIMARY KEY,
    building_id   INTEGER NOT NULL REFERENCES buildings(id) ON DELETE CASCADE,
    name          TEXT    NOT NULL,
    level         INTEGER NOT NULL DEFAULT 0,
    width         INTEGER NOT NULL DEFAULT 1200,
    height        INTEGER NOT NULL DEFAULT 800,
    image_version INTEGER NOT NULL DEFAULT 0,
    created_at    INTEGER NOT NULL
  );
  CREATE INDEX floors_building ON floors(building_id);

  CREATE TABLE floor_images (
    floor_id   INTEGER PRIMARY KEY REFERENCES floors(id) ON DELETE CASCADE,
    mime       TEXT    NOT NULL,
    data       BLOB    NOT NULL,
    updated_at INTEGER NOT NULL
  );

  CREATE TABLE rooms (
    id          INTEGER PRIMARY KEY,
    floor_id    INTEGER NOT NULL REFERENCES floors(id) ON DELETE CASCADE,
    name        TEXT    NOT NULL,
    kind        TEXT    NOT NULL DEFAULT 'room' CHECK (kind IN ('room', 'desk', 'area')),
    capacity    INTEGER NOT NULL DEFAULT 0,
    equipment   TEXT    NOT NULL DEFAULT '[]',
    description TEXT    NOT NULL DEFAULT '',
    shape       TEXT,
    bookable    INTEGER NOT NULL DEFAULT 1,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
  );
  CREATE INDEX rooms_floor ON rooms(floor_id);

  CREATE TABLE bookings (
    id              INTEGER PRIMARY KEY,
    room_id         INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    user_id         INTEGER NOT NULL REFERENCES users(id),
    type            TEXT    NOT NULL DEFAULT 'booking' CHECK (type IN ('booking', 'block')),
    title           TEXT    NOT NULL,
    description     TEXT    NOT NULL DEFAULT '',
    is_private      INTEGER NOT NULL DEFAULT 0,
    start_ts        INTEGER NOT NULL,
    end_ts          INTEGER NOT NULL,
    status          TEXT    NOT NULL DEFAULT 'confirmed' CHECK (status IN ('confirmed', 'cancelled')),
    series_id       TEXT,
    sequence        INTEGER NOT NULL DEFAULT 0,
    cancel_reason   TEXT,
    cancelled_by    INTEGER REFERENCES users(id),
    time_changed_at INTEGER NOT NULL,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL,
    CHECK (end_ts > start_ts)
  );
  CREATE INDEX bookings_room_time ON bookings(room_id, start_ts) WHERE status = 'confirmed';
  CREATE INDEX bookings_start     ON bookings(start_ts) WHERE status = 'confirmed';
  CREATE INDEX bookings_user      ON bookings(user_id, start_ts);
  CREATE INDEX bookings_series    ON bookings(series_id);

  -- Letzte Verteidigungslinie gegen Doppelbuchungen: Selbst wenn ein Fehler in der
  -- Anwendung eine Prüfung umgehen würde, lehnt die Datenbank überlappende Buchungen ab.
  CREATE TRIGGER bookings_no_overlap_insert
  BEFORE INSERT ON bookings
  WHEN NEW.status = 'confirmed'
  BEGIN
    SELECT RAISE(ABORT, 'BOOKING_CONFLICT')
    WHERE EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.room_id = NEW.room_id AND b.status = 'confirmed'
        AND b.start_ts < NEW.end_ts AND b.end_ts > NEW.start_ts
    );
  END;

  CREATE TRIGGER bookings_no_overlap_update
  BEFORE UPDATE OF room_id, start_ts, end_ts, status ON bookings
  WHEN NEW.status = 'confirmed'
  BEGIN
    SELECT RAISE(ABORT, 'BOOKING_CONFLICT')
    WHERE EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.room_id = NEW.room_id AND b.id <> NEW.id AND b.status = 'confirmed'
        AND b.start_ts < NEW.end_ts AND b.end_ts > NEW.start_ts
    );
  END;

  CREATE TABLE booking_attendees (
    booking_id INTEGER NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
    email      TEXT    NOT NULL COLLATE NOCASE,
    PRIMARY KEY (booking_id, email)
  );
  CREATE INDEX attendees_email ON booking_attendees(email);

  CREATE TABLE notifications (
    id         INTEGER PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type       TEXT    NOT NULL,
    title      TEXT    NOT NULL,
    body       TEXT    NOT NULL DEFAULT '',
    link       TEXT,
    booking_id INTEGER REFERENCES bookings(id) ON DELETE SET NULL,
    created_at INTEGER NOT NULL,
    read_at    INTEGER
  );
  CREATE INDEX notifications_user ON notifications(user_id, created_at);

  CREATE TABLE email_outbox (
    id              INTEGER PRIMARY KEY,
    to_email        TEXT    NOT NULL,
    subject         TEXT    NOT NULL,
    text_body       TEXT    NOT NULL,
    html_body       TEXT,
    ics             TEXT,
    ics_method      TEXT,
    attachments     TEXT,
    status          TEXT    NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'failed')),
    attempts        INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL,
    last_error      TEXT,
    created_at      INTEGER NOT NULL,
    sent_at         INTEGER
  );
  CREATE INDEX outbox_due ON email_outbox(status, next_attempt_at);

  CREATE TABLE reminders_sent (
    booking_id INTEGER NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sent_at    INTEGER NOT NULL,
    PRIMARY KEY (booking_id, user_id)
  );

  CREATE TABLE room_watches (
    id         INTEGER PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    room_id    INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    start_ts   INTEGER NOT NULL,
    end_ts     INTEGER NOT NULL,
    created_at INTEGER NOT NULL
  );
  CREATE INDEX watches_room ON room_watches(room_id, start_ts);

  CREATE TABLE settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );

  CREATE TABLE audit_log (
    id         INTEGER PRIMARY KEY,
    user_id    INTEGER REFERENCES users(id) ON DELETE SET NULL,
    action     TEXT    NOT NULL,
    details    TEXT    NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL
  );
  CREATE INDEX audit_created ON audit_log(created_at);
  `,
];
