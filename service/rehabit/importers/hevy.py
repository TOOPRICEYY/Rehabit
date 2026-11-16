"""Import a Hevy CSV export (one row per set).

Hevy has no side field. For sessions the profile marks as rehab sessions, the side
comes from the exercise note when it names one ("Right arm"), else from the
profile's per-exercise rule, and is stored with side_inferred=1 either way.
"""

from __future__ import annotations

import csv
import hashlib
import re
import sqlite3
from datetime import datetime
from pathlib import Path

from .. import db, library
from ..profile import LB_TO_KG, Profile

SOURCE = "hevy_csv"
_SIDE_NOTE = re.compile(r"\b(left|right)\s+(arm|leg|side|hand)\b", re.I)
_HOLD_NOTE = re.compile(r"^\s*iso", re.I)
_PAIN_NOTE = re.compile(r"(\d+(?:\.\d+)?)\s*/\s*10\s*pain", re.I)


def _parse_time(text: str) -> datetime:
    return datetime.strptime(text.strip(), "%d %b %Y, %H:%M")


def _num(text: str | None) -> float | None:
    if text is None or text.strip() == "":
        return None
    return float(text)


def import_csv(con: sqlite3.Connection, path: str | Path, profile: Profile) -> dict:
    con.execute("DELETE FROM set_entry WHERE source = ?", (SOURCE,))
    con.execute("DELETE FROM session WHERE source = ?", (SOURCE,))
    rehab_titles = {t.lower() for t in profile.rehab_session_titles}
    sessions: dict[str, str] = {}
    counts = {"sessions": 0, "sets": 0, "unmapped": 0, "sides_inferred": 0, "holds_inferred": 0}
    with open(path, newline="", encoding="utf-8") as fh:
        for position, row in enumerate(csv.DictReader(fh)):
            start = _parse_time(row["start_time"])
            key = f"{row['title']}|{row['start_time']}"
            if key not in sessions:
                session_id = "hevy:" + hashlib.sha1(key.encode()).hexdigest()[:12]
                sessions[key] = session_id
                end = _parse_time(row["end_time"]) if row.get("end_time") else None
                con.execute(
                    "INSERT INTO session(id, start, end, day, kind, title, minutes, notes,"
                    " source, source_id, imported_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    (
                        session_id, start.isoformat(sep=" ", timespec="minutes"),
                        end.isoformat(sep=" ", timespec="minutes") if end else None,
                        start.date().isoformat(), "gym", row["title"],
                        (end - start).total_seconds() / 60 if end else None,
                        row.get("description") or None, SOURCE, key, db.now(),
                    ),
                )
                counts["sessions"] += 1
            session_id = sessions[key]
            name = row["exercise_title"]
            exercise_id = library.match_exercise(name)
            if exercise_id is None:
                counts["unmapped"] += 1
            note = row.get("exercise_notes") or ""
            is_rehab = row["title"].strip().lower() in rehab_titles

            side, side_inferred = "both", 0
            if is_rehab:
                noted = _SIDE_NOTE.search(note)
                if noted:
                    side, side_inferred = noted.group(1).lower(), 1
                elif exercise_id in profile.rehab_side_rules:
                    side, side_inferred = profile.rehab_side_rules[exercise_id], 1
            counts["sides_inferred"] += side_inferred

            reps = _num(row.get("reps"))
            hold = _num(row.get("duration_seconds"))
            kind, kind_inferred = ("hold", 0) if hold and not reps else ("reps", 0)
            if is_rehab and reps and _HOLD_NOTE.search(note):
                # In these sessions the reps field was used for seconds held.
                kind, kind_inferred, hold, reps = "hold", 1, reps, None
                counts["holds_inferred"] += 1

            weight_lb = _num(row.get("weight_lbs"))
            bw_share = library.EXERCISES[exercise_id][1] if exercise_id else 0.0
            if weight_lb is None and bw_share > 0:
                convention, load_kg = "bodyweight", profile.bodyweight_kg * bw_share
            elif weight_lb is None:
                convention, load_kg = None, None
            elif bw_share > 0:
                convention = "bodyweight_plus"
                load_kg = profile.bodyweight_kg * bw_share + weight_lb * LB_TO_KG
            else:
                convention = "per_hand" if "dumbbell" in name.lower() else "total"
                load_kg = weight_lb * LB_TO_KG

            pain = _PAIN_NOTE.search(note)
            con.execute(
                "INSERT INTO set_entry(id, session_id, day, position, exercise_id,"
                " source_exercise, granularity, side, side_inferred, kind, kind_inferred,"
                " set_count, reps, hold_seconds, load_value, load_unit, load_convention,"
                " load_kg, load_max_kg, set_type, rpe, pain, notes, source)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    f"{session_id}:{position}", session_id, start.date().isoformat(),
                    position, exercise_id, name, "set", side, side_inferred, kind,
                    kind_inferred, 1, reps, hold, weight_lb,
                    "lb" if weight_lb is not None else None, convention, load_kg, load_kg,
                    row.get("set_type") or None, _num(row.get("rpe")),
                    float(pain.group(1)) if pain else None, note or None, SOURCE,
                ),
            )
            counts["sets"] += 1
    con.commit()
    return counts
