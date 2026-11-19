"""SQLite access. The schema lives in schema.sql beside this file."""

from __future__ import annotations

import sqlite3
from datetime import datetime
from pathlib import Path

SCHEMA_PATH = Path(__file__).with_name("schema.sql")
SCHEMA_VERSION = "1"


def connect(path: str | Path, read_only: bool = False) -> sqlite3.Connection:
    if read_only:
        con = sqlite3.connect(f"file:{Path(path).resolve()}?mode=ro", uri=True)
    else:
        con = sqlite3.connect(str(path))
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys = ON")
    return con


# Columns added after a database may already exist. CREATE TABLE IF NOT EXISTS
# leaves an older table as it is, so each is added here when missing.
ADDED_COLUMNS = (
    ("session", "effort", "REAL"),        # how hard the session felt, 0..10
    ("set_entry", "tempo", "TEXT"),       # seconds per phase of a rep, "3-1-1-0"
    ("injury", "plan", "TEXT"),           # JSON: the limits and milestones set for it
    ("session", "counts_as", "TEXT"),     # the activity pattern the person chose for a recording
)


def init(con: sqlite3.Connection) -> None:
    con.executescript(SCHEMA_PATH.read_text())
    for table, column, kind in ADDED_COLUMNS:
        have = {r[1] for r in con.execute(f"PRAGMA table_info({table})")}
        if column not in have:
            con.execute(f"ALTER TABLE {table} ADD COLUMN {column} {kind}")
    con.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', ?)",
        (SCHEMA_VERSION,),
    )
    con.commit()


def now() -> str:
    return datetime.now().isoformat(timespec="seconds")


def rows(con: sqlite3.Connection, sql: str, params: tuple | dict = ()) -> list[dict]:
    return [dict(r) for r in con.execute(sql, params).fetchall()]
