-- Rehabit schema, phase 0. One SQLite file; the phone app will share these tables.
-- Conventions: ids are text, times are ISO local strings, loads keep the unit as
-- entered plus a kilogram value, and every imported row names its source.

CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

CREATE TABLE IF NOT EXISTS tissue (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,            -- muscle | tendon | attachment | joint
  region TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS exercise (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  bodyweight_share REAL NOT NULL DEFAULT 0   -- fraction of body weight moved per rep
);

CREATE TABLE IF NOT EXISTS exercise_tissue (
  exercise_id TEXT NOT NULL REFERENCES exercise(id),
  tissue_id TEXT NOT NULL REFERENCES tissue(id),
  share REAL NOT NULL,           -- 0..1
  role TEXT NOT NULL,            -- prime | assist | stabiliser | end_range
  estimate_source TEXT NOT NULL DEFAULT 'default',
  PRIMARY KEY (exercise_id, tissue_id)
);

CREATE TABLE IF NOT EXISTS session (
  id TEXT PRIMARY KEY,
  start TEXT NOT NULL,
  end TEXT,
  day TEXT NOT NULL,
  kind TEXT NOT NULL,            -- gym | sport | cardio | daily_life
  title TEXT,
  activity_type TEXT,            -- source's type key for non-gym sessions
  minutes REAL,
  distance_km REAL,
  avg_hr REAL,
  max_hr REAL,
  notes TEXT,
  source TEXT NOT NULL,
  source_id TEXT NOT NULL,
  imported_at TEXT NOT NULL,
  effort REAL,                   -- how hard the session felt, 0..10, when the person said
  UNIQUE (source, source_id)
);
CREATE INDEX IF NOT EXISTS session_day ON session(day);

-- One row per logged set, or per exercise total when the source gives no sets.
CREATE TABLE IF NOT EXISTS set_entry (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES session(id),
  day TEXT NOT NULL,
  position INTEGER NOT NULL,
  exercise_id TEXT,              -- null when the source name could not be mapped
  source_exercise TEXT NOT NULL, -- the name exactly as the source gave it
  granularity TEXT NOT NULL,     -- set | exercise_total
  side TEXT NOT NULL,            -- left | right | both
  side_inferred INTEGER NOT NULL DEFAULT 0,
  kind TEXT NOT NULL,            -- reps | hold
  kind_inferred INTEGER NOT NULL DEFAULT 0,
  set_count INTEGER NOT NULL DEFAULT 1,
  reps REAL,
  hold_seconds REAL,
  load_value REAL,               -- as entered, per the convention below
  load_unit TEXT,
  load_convention TEXT,          -- per_hand | total | bodyweight | bodyweight_plus
  load_kg REAL,                  -- arithmetic value; average per rep for totals
  load_max_kg REAL,              -- heaviest load in the row
  set_type TEXT,
  rpe REAL,
  pain REAL,                     -- 0..10 when the source recorded it
  notes TEXT,
  source TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS set_day ON set_entry(day);
CREATE INDEX IF NOT EXISTS set_exercise ON set_entry(exercise_id, day);

CREATE TABLE IF NOT EXISTS injury (
  id TEXT PRIMARY KEY,
  label TEXT NOT NULL,
  side TEXT NOT NULL,
  onset TEXT NOT NULL,
  onset_precision TEXT NOT NULL,  -- day | week | month
  onset_recalled INTEGER NOT NULL DEFAULT 1,
  mechanism TEXT,
  stage TEXT,
  tissues TEXT NOT NULL,          -- JSON list of tissue ids
  activity_types TEXT NOT NULL DEFAULT '[]',  -- JSON list of activity type keys
  notes TEXT
);

CREATE TABLE IF NOT EXISTS daily_metric (
  day TEXT NOT NULL,
  metric TEXT NOT NULL,
  value REAL NOT NULL,
  unit TEXT,
  source TEXT NOT NULL,
  PRIMARY KEY (day, metric, source)
);

CREATE TABLE IF NOT EXISTS dose_event (
  id TEXT PRIMARY KEY,
  taken_at TEXT NOT NULL,
  day TEXT NOT NULL,
  drug TEXT NOT NULL,
  amount REAL,
  unit TEXT,
  route TEXT,
  site TEXT,
  status TEXT,
  source TEXT NOT NULL
);

-- One question about one injury at one moment, from the app. `pain` is null
-- until answered: a skipped check is missing, never zero.
CREATE TABLE IF NOT EXISTS pain_check (
  id TEXT PRIMARY KEY,
  injury_id TEXT NOT NULL,
  session_id TEXT,
  moment TEXT NOT NULL,          -- after_session | evening | next_morning | 24h | 48h | baseline
  due_at TEXT NOT NULL,
  day TEXT NOT NULL,
  answered_at TEXT,
  pain REAL,
  pain_type TEXT,
  notes TEXT,
  source TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS pain_check_day ON pain_check(day);

-- Which daily_metric sources last arrived through the app's export, so a new
-- export replaces them and leaves directly imported sources alone.
CREATE TABLE IF NOT EXISTS app_metric_source (source TEXT PRIMARY KEY);

-- Derived tables. Rebuilt from scratch by `rehabit compute`; never edited by hand.
CREATE TABLE IF NOT EXISTS tissue_load_day (
  day TEXT NOT NULL,
  tissue_id TEXT NOT NULL,
  side TEXT NOT NULL,            -- left | right
  dose REAL NOT NULL,
  sets REAL NOT NULL,
  reps REAL NOT NULL,
  acute REAL NOT NULL,
  chronic REAL NOT NULL,
  walking_dose REAL NOT NULL DEFAULT 0,    -- the part of dose from daily steps
  walking_chronic REAL NOT NULL DEFAULT 0, -- the part of chronic from daily steps
  PRIMARY KEY (day, tissue_id, side)
);

CREATE TABLE IF NOT EXISTS flag (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  day TEXT NOT NULL,
  kind TEXT NOT NULL,
  scope_type TEXT NOT NULL,      -- tissue | exercise | activity
  scope TEXT NOT NULL,
  exercise_id TEXT,              -- set for exercise-scoped flags
  side TEXT,
  value REAL,
  threshold REAL,
  detail TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS flag_day ON flag(day);
