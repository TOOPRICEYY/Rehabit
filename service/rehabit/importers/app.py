"""Import the Rehabit app's export file (the JSON it writes for backup and sync).

The app stores one record per set with a movement pattern, which is this
service's exercise id, so nothing has to be guessed here: side, kind and what
the load means are as the person logged them. Workouts the app itself brought
in from another log carry that log's prefix in their id ("hevy:", "garmin:");
they are left out when this build already imports that log directly, so
nothing is counted twice.
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from .. import db, library
from ..profile import LB_TO_KG, Profile

SOURCE = "rehabit_app"
SUPPORTED_SCHEMA = 1


def _local(text: str | None) -> str | None:
    """'2026-11-16T21:58:00.000Z' as '2026-11-16 21:58'. Kept in UTC: the day the
    session belongs to is stored separately by the app and is used for all sums."""
    return text[:16].replace("T", " ") if text else None


def _minutes(start: str | None, end: str | None) -> float | None:
    from datetime import datetime
    if not start or not end:
        return None
    try:
        a = datetime.fromisoformat(start.replace("Z", "+00:00"))
        b = datetime.fromisoformat(end.replace("Z", "+00:00"))
    except ValueError:
        return None
    return max(0.0, (b - a).total_seconds() / 60)


def _load_kg(s: dict, bodyweight_kg: float) -> float | None:
    value, unit = s.get("loadValue"), s.get("loadUnit") or "lb"
    kg = None if value is None else value * (LB_TO_KG if unit == "lb" else 1.0)
    pattern = s.get("pattern")
    share = library.EXERCISES[pattern][1] if pattern in library.EXERCISES else 0.0
    convention = s.get("convention")
    if convention == "bodyweight":
        return bodyweight_kg * share if share > 0 else None
    if convention == "bodyweight_plus":
        return bodyweight_kg * share + (kg or 0.0)
    return kg


def import_export(con: sqlite3.Connection, path: str | Path, profile: Profile,
                  skip_prefixes: tuple[str, ...] = ()) -> dict:
    raw = json.loads(Path(path).read_text())
    if raw.get("schemaVersion", 1) > SUPPORTED_SCHEMA:
        raise ValueError("this export was written by a newer version of the app")
    for table in ("set_entry", "session", "pain_check"):
        con.execute(f"DELETE FROM {table} WHERE source = ?", (SOURCE,))
    con.execute("DELETE FROM daily_metric WHERE source IN (SELECT DISTINCT source FROM app_metric_source)")
    con.execute("DELETE FROM app_metric_source")
    con.execute("DELETE FROM injury WHERE id LIKE 'app:%'")

    bodyweight_kg = (raw.get("profile") or {}).get("bodyweightKg") or profile.bodyweight_kg
    counts = {"sessions": 0, "sets": 0, "unmapped": 0, "skipped_sessions": 0, "in_progress": 0,
              "injuries": 0, "pain_checks": 0, "daily_metrics": 0}
    kept: set[str] = set()
    for w in raw.get("workouts", []):
        if w["id"].startswith(skip_prefixes) if skip_prefixes else False:
            counts["skipped_sessions"] += 1
            continue
        if not w.get("end"):          # still being logged on the phone
            counts["in_progress"] += 1
            continue
        kept.add(w["id"])
        con.execute(
            "INSERT INTO session(id, start, end, day, kind, title, minutes, notes, source,"
            " source_id, imported_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            ("app:" + w["id"], _local(w["start"]), _local(w.get("end")), w["startDay"], "gym",
             w.get("title"), _minutes(w["start"], w.get("end")), w.get("notes") or None,
             SOURCE, w["id"], db.now()))
        counts["sessions"] += 1

    for s in raw.get("sets", []):
        if s["workoutID"] not in kept:
            continue
        pattern = s.get("pattern") if s.get("pattern") in library.EXERCISES else None
        if pattern is None:
            counts["unmapped"] += 1
        kg = _load_kg(s, bodyweight_kg)
        rir = s.get("repsInReserve")
        con.execute(
            "INSERT INTO set_entry(id, session_id, day, position, exercise_id, source_exercise,"
            " granularity, side, side_inferred, kind, set_count, reps, hold_seconds, load_value, load_unit,"
            " load_convention, load_kg, load_max_kg, set_type, rpe, pain, notes, source)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            ("app:" + s["id"], "app:" + s["workoutID"], s["workoutDay"], s.get("position", 0),
             pattern, s["exercise"], "set", s.get("side", "both"), 1 if s.get("sideInferred") else 0,
             s.get("kind", "reps"), 1,
             s.get("reps"), s.get("holdSeconds"), s.get("loadValue"),
             s.get("loadUnit") if s.get("loadValue") is not None else None, s.get("convention"),
             kg, kg, "warmup" if s.get("isWarmup") else "normal",
             None if rir is None else 10 - rir, s.get("pain"), s.get("notes") or None, SOURCE))
        counts["sets"] += 1

    for inj in raw.get("injuries", []):
        con.execute(
            "INSERT OR REPLACE INTO injury(id, label, side, onset, onset_precision, onset_recalled,"
            " mechanism, stage, tissues, activity_types, notes) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            ("app:" + inj["id"], inj["label"], inj["side"], inj["onset"],
             inj.get("onsetPrecision", "day"), 1, inj.get("mechanism") or None,
             "resolved" if inj.get("resolvedOn") else None, json.dumps(inj.get("tissues", [])),
             "[]", inj.get("notes") or None))
        counts["injuries"] += 1

    for c in raw.get("painChecks", []):
        con.execute(
            "INSERT OR REPLACE INTO pain_check(id, injury_id, session_id, moment, due_at, day,"
            " answered_at, pain, pain_type, notes, source) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            ("app:" + c["id"], "app:" + c["injuryID"],
             "app:" + c["workoutID"] if c.get("workoutID") else None, c["moment"],
             _local(c["dueAt"]), c["dueDay"], _local(c.get("answeredAt")), c.get("pain"),
             c.get("painType"), c.get("notes") or None, SOURCE))
        counts["pain_checks"] += 1

    for m in raw.get("dailyMetrics", []):
        # Values the phone read from a watch keep the watch's own source name,
        # so the same night from two routes is one row, not two.
        con.execute("INSERT OR REPLACE INTO daily_metric(day, metric, value, unit, source)"
                    " VALUES (?,?,?,?,?)", (m["day"], m["metric"], m["value"], None, m["source"]))
        con.execute("INSERT OR IGNORE INTO app_metric_source(source) VALUES (?)", (m["source"],))
        counts["daily_metrics"] += 1
    con.commit()
    return counts
