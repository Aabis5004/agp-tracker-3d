import Database from 'better-sqlite3';
import { mkdirSync } from 'fs';
import { dirname } from 'path';

const DB_PATH = process.env.DB_PATH || './data/agp.db';

mkdirSync(dirname(DB_PATH), { recursive: true });

const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');

db.exec(`
  CREATE TABLE IF NOT EXISTS tracks (
    id TEXT PRIMARY KEY,
    name TEXT,
    difficulty TEXT,
    point_count INTEGER,
    starts_at TEXT,
    started INTEGER,
    over INTEGER,
    racer_count INTEGER,
    winner_login TEXT,
    question_cost REAL,
    guess_cost REAL,
    max_racers INTEGER,
    created_at TEXT,
    first_seen TEXT,
    last_updated TEXT
  );

  CREATE TABLE IF NOT EXISTS racers (
    track_id TEXT,
    login TEXT,
    idx INTEGER,
    point_count INTEGER,
    finished INTEGER,
    duration_ms INTEGER,
    questions_asked INTEGER,
    guess_count INTEGER,
    updated_at TEXT,
    PRIMARY KEY (track_id, login)
  );

  CREATE TABLE IF NOT EXISTS snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    track_id TEXT,
    login TEXT,
    idx INTEGER,
    finished INTEGER,
    questions_asked INTEGER,
    guess_count INTEGER,
    taken_at TEXT
  );

  CREATE INDEX IF NOT EXISTS idx_snap_track ON snapshots(track_id, taken_at);
  CREATE INDEX IF NOT EXISTS idx_racers_login ON racers(login);
`);

export const upsertTrack = db.prepare(`
  INSERT INTO tracks (id, name, difficulty, point_count, starts_at, started, over,
                      racer_count, winner_login, question_cost, guess_cost, max_racers,
                      created_at, first_seen, last_updated)
  VALUES (@id, @name, @difficulty, @point_count, @starts_at, @started, @over,
          @racer_count, @winner_login, @question_cost, @guess_cost, @max_racers,
          @created_at, @now, @now)
  ON CONFLICT(id) DO UPDATE SET
    name=@name, started=@started, over=@over, racer_count=@racer_count,
    winner_login=@winner_login, last_updated=@now
`);

export const upsertRacer = db.prepare(`
  INSERT INTO racers (track_id, login, idx, point_count, finished, duration_ms,
                      questions_asked, guess_count, updated_at)
  VALUES (@track_id, @login, @idx, @point_count, @finished, @duration_ms,
          @questions_asked, @guess_count, @now)
  ON CONFLICT(track_id, login) DO UPDATE SET
    idx=@idx, finished=@finished, duration_ms=@duration_ms,
    questions_asked=@questions_asked, guess_count=@guess_count, updated_at=@now
`);

export const insertSnapshot = db.prepare(`
  INSERT INTO snapshots (track_id, login, idx, finished, questions_asked, guess_count, taken_at)
  VALUES (@track_id, @login, @idx, @finished, @questions_asked, @guess_count, @now)
`);

export const getTracks = db.prepare(`SELECT * FROM tracks ORDER BY starts_at DESC`);
export const getTrack = db.prepare(`SELECT * FROM tracks WHERE id = ?`);
export const getRacers = db.prepare(`SELECT * FROM racers WHERE track_id = ?`);
export const getAllRacers = db.prepare(`SELECT * FROM racers`);
export const getSnapshots = db.prepare(`SELECT * FROM snapshots WHERE track_id = ? ORDER BY taken_at`);

export default db;
