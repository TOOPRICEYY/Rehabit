"""Import Garmin activities from the bridge's activity listing (JSON files).

The listing gives per-exercise totals for strength activities (sets, reps, average
and heaviest weight), not individual sets, so each becomes one set_entry row with
granularity='exercise_total'. Exact per-set data from the original activity files
is a later importer; this one is enough to drive the ledger and flags.
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from .. import db, library
from ..profile import Profile

SOURCE = "garmin_bridge"
GYM_TYPES = {"strength_training"}
SKIP_TYPES = {"other", "meditation", "breathwork"}
# A "pull up" logged with more than this is taken to be a pulldown stack weight,
# not weight added to a body-weight pull-up.
MAX_ADDED_PULLUP_KG = 20.5


def _strength_rows(activity: dict, profile: Profile) -> list[dict]:
    out = []
    for ex in (activity.get("strength") or {}).get("exercises", []):
        reps = ex.get("reps") or 0
        if reps <= 0:
            continue
        name = ex.get("exercise") or "unknown"
        exercise_id = library.match_exercise(name) or library.match_exercise(
            ex.get("category") or ""
        )
        avg, top = ex.get("avg_weight_per_rep_kg"), ex.get("max_weight_kg")
        convention, notes = "total", None
        if exercise_id == "pull_up" and avg and avg > MAX_ADDED_PULLUP_KG:
            exercise_id, notes = "pulldown", "treated as a pulldown: weight too high to be added load"
        bw_share = library.EXERCISES[exercise_id][1] if exercise_id else 0.0
        if bw_share > 0:
            base = profile.bodyweight_kg * bw_share
            convention = "bodyweight_plus" if avg else "bodyweight"
            load_kg, load_max_kg = base + (avg or 0), base + (top or 0)
        elif avg:
            load_kg, load_max_kg = avg, top or avg
        else:
            convention, load_kg, load_max_kg = None, None, None
        out.append({
            "exercise_id": exercise_id, "source_exercise": name.strip(),
            "set_count": ex.get("sets") or 1, "reps": reps, "load_value": avg,
            "convention": convention, "load_kg": load_kg, "load_max_kg": load_max_kg,
            "notes": notes,
        })
    return out


def import_listing(con: sqlite3.Connection, paths: list[str | Path], profile: Profile) -> dict:
    con.execute("DELETE FROM set_entry WHERE source = ?", (SOURCE,))
    con.execute("DELETE FROM session WHERE source = ?", (SOURCE,))
    counts = {"sessions": 0, "gym": 0, "cardio": 0, "rows": 0, "unmapped_rows": 0, "skipped": 0}
    seen: set[str] = set()
    for path in paths:
        for act in json.loads(Path(path).read_text()).get("activities", []):
            source_id = str(act["activity_id"])
            type_key = act.get("type_key") or "unknown"
            if source_id in seen:
                continue
            seen.add(source_id)
            if type_key in SKIP_TYPES:
                counts["skipped"] += 1
                continue
            is_gym = type_key in GYM_TYPES
            session_id = f"garmin:{source_id}"
            con.execute(
                "INSERT INTO session(id, start, day, kind, title, activity_type, minutes,"
                " distance_km, avg_hr, max_hr, source, source_id, imported_at)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    session_id, act["start"], act["start"][:10],
                    "gym" if is_gym else "cardio", act.get("name"),
                    None if is_gym else type_key, act.get("duration_minutes"),
                    act.get("distance_km"), act.get("avg_hr"), act.get("max_hr"),
                    SOURCE, source_id, db.now(),
                ),
            )
            counts["sessions"] += 1
            counts["gym" if is_gym else "cardio"] += 1
            if not is_gym:
                continue
            for position, r in enumerate(_strength_rows(act, profile)):
                if r["exercise_id"] is None:
                    counts["unmapped_rows"] += 1
                con.execute(
                    "INSERT INTO set_entry(id, session_id, day, position, exercise_id,"
                    " source_exercise, granularity, side, kind, set_count, reps, load_value,"
                    " load_unit, load_convention, load_kg, load_max_kg, notes, source)"
                    " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (
                        f"{session_id}:{position}", session_id, act["start"][:10], position,
                        r["exercise_id"], r["source_exercise"], "exercise_total", "both",
                        "reps", r["set_count"], r["reps"], r["load_value"],
                        "kg" if r["load_value"] else None, r["convention"], r["load_kg"],
                        r["load_max_kg"], r["notes"], SOURCE,
                    ),
                )
                counts["rows"] += 1
    con.commit()
    return counts


def pair_sides(con: sqlite3.Connection) -> int:
    """Where the old log holds one side of an exercise on a day, the watch's entry
    for the same exercise that day is the other side. Marks the result as inferred."""
    opposite = {"left": "right", "right": "left"}
    pairs = con.execute(
        "SELECT DISTINCT day, exercise_id, side FROM set_entry"
        " WHERE source != ? AND side IN ('left','right') AND exercise_id IS NOT NULL",
        (SOURCE,),
    ).fetchall()
    changed = 0
    for day, exercise_id, side in pairs:
        cur = con.execute(
            "UPDATE set_entry SET side = ?, side_inferred = 1"
            " WHERE source = ? AND day = ? AND exercise_id = ? AND side = 'both'",
            (opposite[side], SOURCE, day, exercise_id),
        )
        changed += cur.rowcount
    con.commit()
    return changed
