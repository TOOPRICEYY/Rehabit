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


def init(con: sqlite3.Connection) -> None:
    con.executescript(SCHEMA_PATH.read_text())
    con.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', ?)",
        (SCHEMA_VERSION,),
    )
    con.commit()


def now() -> str:
    return datetime.now().isoformat(timespec="seconds")


def rows(con: sqlite3.Connection, sql: str, params: tuple | dict = ()) -> list[dict]:
    return [dict(r) for r in con.execute(sql, params).fetchall()]
