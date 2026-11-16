"""Mirror the dose log's backup file as read-only dose events."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

SOURCE = "doestrack"


def import_backup(con: sqlite3.Connection, path: str | Path) -> dict:
    raw = json.loads(Path(path).read_text())
    meds = {m["id"]: m for m in raw.get("medications", [])}
    con.execute("DELETE FROM dose_event WHERE source = ?", (SOURCE,))
    count = 0
    for log in raw.get("logs", []):
        taken = log.get("takenAt") or log.get("scheduledAt")
        if not taken:
            continue
        med = meds.get(log.get("medicationID"), {})
        con.execute(
            "INSERT OR REPLACE INTO dose_event(id, taken_at, day, drug, amount, unit, route,"
            " site, status, source) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (
                log["id"], taken, taken[:10], med.get("name", "unknown"), log.get("amount"),
                med.get("unit"), log.get("method"), log.get("site"), log.get("status"), SOURCE,
            ),
        )
        count += 1
    con.commit()
    return {"dose_events": count, "schema_version": raw.get("schemaVersion")}
