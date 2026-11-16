"""Nightly and daily Garmin values: heart rate variability, sleep, resting heart
rate and steps.

Reads saved results of the Garmin sleep history ({"nights": [...]}) and daily
summary ({"days": [...]}). A night is filed under the date it ended on. A value
that is missing stays missing: nothing is stored as zero.
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Iterable

SOURCE = "garmin"
UNITS = {"hrv_ms": "ms", "sleep_minutes": "min", "sleep_score": "score", "sleep_hr": "bpm",
         "resting_hr": "bpm", "steps": "steps"}


def _night(entry: dict) -> dict:
    hrv = entry.get("hrv") or {}
    return {"hrv_ms": hrv.get("last_night_avg_ms"), "sleep_minutes": entry.get("total_minutes"),
            "sleep_score": entry.get("score"), "sleep_hr": entry.get("avg_heart_rate")}


def _day(entry: dict) -> dict:
    return {"resting_hr": (entry.get("heart_rate") or {}).get("resting"),
            "steps": entry.get("steps")}


def import_files(con: sqlite3.Connection, paths: Iterable[str | Path]) -> dict:
    con.execute("DELETE FROM daily_metric WHERE source = ?", (SOURCE,))
    counts: dict[str, int] = {}
    for path in paths:
        raw = json.loads(Path(path).read_text())
        entries = [(e, _night) for e in raw.get("nights", [])] + [(e, _day) for e in raw.get("days", [])]
        for entry, read in entries:
            day = entry.get("date")
            if not day or entry.get("no_data"):
                continue
            for metric, value in read(entry).items():
                # A zero here is a watch that was not worn, not a measurement.
                if value is None or value <= 0:
                    continue
                con.execute(
                    "INSERT OR REPLACE INTO daily_metric(day, metric, value, unit, source)"
                    " VALUES (?,?,?,?,?)", (day, metric, float(value), UNITS[metric], SOURCE))
                counts[metric] = counts.get(metric, 0) + 1
    con.commit()
    return counts
