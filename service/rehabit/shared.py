"""Files shared with the app, so the phone and the service cannot drift apart.

`library.json` is the tissue and exercise library. The `ledger.json` fixture is a
small made-up training history with the doses this service computes for it; the
app's tests must reproduce those numbers.
"""

from __future__ import annotations

import json
from datetime import date, timedelta
from pathlib import Path

from . import db, ledger, library

CORE = Path(__file__).resolve().parents[2] / "app" / "RehabitCore"
LIBRARY = CORE / "Sources" / "RehabitCore" / "Resources" / "library.json"
VECTORS = CORE / "Tests" / "RehabitCoreTests" / "Fixtures" / "ledger.json"


def _vector_sets() -> list[dict]:
    start = date(2025, 1, 6)
    plan = [  # (day offset, exercise, pattern, side, kind, reps, hold seconds, load kg)
        (0, "Bench Press (Dumbbell)", "press_horizontal", "both", "reps", 10, None, 20.0),
        (0, "Bench Press (Dumbbell)", "press_horizontal", "both", "reps", 8, None, 22.5),
        (0, "Single-Leg Extension (Machine)", "leg_extension", "right", "hold", None, 45, 15.0),
        (2, "Bench Press (Dumbbell)", "press_horizontal", "both", "reps", 10, None, 25.0),
        (2, "Bench Press (Dumbbell)", "press_horizontal", "both", "reps", 10, None, 20.0),
        (2, "Pull-Up", "pull_up", "both", "reps", 6, None, 72.0),
        (3, "Single-Arm Row (Dumbbell)", "row", "left", "reps", 12, None, 18.0),
        (3, "Single-Arm Row (Dumbbell)", "row", "right", "reps", 12, None, 24.0),
        (9, "Single-Leg Extension (Machine)", "leg_extension", "right", "reps", 12, None, 20.0),
        (9, "Mystery Movement", None, "both", "reps", 10, None, 30.0),
        (40, "Bench Press (Dumbbell)", "press_horizontal", "both", "reps", 10, None, 10.0),
        (41, "Bench Press (Dumbbell)", "press_horizontal", "both", "reps", 5, None, 40.0),
        (41, "Plank", "core", "both", "hold", None, 60, None),
    ]
    return [{"day": (start + timedelta(days=o)).isoformat(), "exercise": name, "pattern": pattern,
             "side": side, "kind": kind, "reps": reps, "holdSeconds": hold, "loadKg": load}
            for o, name, pattern, side, kind, reps, hold, load in plan]


def _vector_steps() -> dict[str, float]:
    """Steps with a gap (a day off the wrist) and a jump, starting after the first sets."""
    start = date(2025, 1, 6)
    plan = {5: 6000, 6: 6400, 7: 5800, 9: 7000, 10: 6600, 12: 14000, 13: 0, 44: 8000}
    return {(start + timedelta(days=o)).isoformat(): v for o, v in plan.items()}


def _vector_activities() -> list[dict]:
    """Recorded activities: known and unknown types, with and without heart rate."""
    start = date(2025, 1, 6)
    plan = [  # (day offset, type key, name, minutes, average HR, max HR)
        (1, "cycling", "Morning Ride", 45.0, 118.0, 150.0),
        (4, "indoor_rowing", "Indoor Rowing", 12.0, 140.0, 172.0),
        (6, "running", "Easy Run", 25.5, 150.0, 181.0),
        (8, "indoor_cardio", "Sauna", 20.0, 120.0, 150.0),
        (10, "yoga", "Yoga", 30.0, 80.0, 105.0),
        (11, "walking", "Walk", 50.0, 95.0, 120.0),
        (12, "indoor_cardio", "Stairmaster", 15.0, None, None),
        (41, "lap_swimming", "Pool", 30.0, 125.0, 160.0),
    ]
    return [{"day": (start + timedelta(days=o)).isoformat(), "type": t, "name": n, "minutes": m,
             "averageHR": a, "maxHR": x} for o, t, n, m, a, x in plan]


def _vector_resting() -> dict[str, float]:
    start = date(2025, 1, 6)
    plan = {0: 52, 1: 50, 3: 55, 5: 49, 6: 51, 9: 53, 30: 48}
    return {(start + timedelta(days=o)).isoformat(): float(v) for o, v in plan.items()}


def ledger_vectors() -> dict:
    con = db.connect(":memory:")
    db.init(con)
    library.seed(con)
    sets = _vector_sets()
    for i, s in enumerate(sets):
        session_id = f"vec:{s['day']}"
        con.execute(
            "INSERT OR IGNORE INTO session(id, start, day, kind, source, source_id, imported_at)"
            " VALUES (?,?,?,?,?,?,?)",
            (session_id, s["day"], s["day"], "gym", "vec", session_id, "x"))
        con.execute(
            "INSERT INTO set_entry(id, session_id, day, position, exercise_id, source_exercise,"
            " granularity, side, kind, reps, hold_seconds, load_kg, load_max_kg, source)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (str(i), session_id, s["day"], i, s["pattern"], s["exercise"], "set", s["side"],
             s["kind"], s["reps"], s["holdSeconds"], s["loadKg"], s["loadKg"], "vec"))
    steps = _vector_steps()
    for day, value in steps.items():
        con.execute("INSERT INTO daily_metric(day, metric, value, source) VALUES (?,?,?,?)",
                    (day, "steps", value, "vec"))
    activities = _vector_activities()
    for i, a in enumerate(activities):
        con.execute(
            "INSERT INTO session(id, start, day, kind, title, activity_type, minutes, avg_hr, max_hr,"
            " source, source_id, imported_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (f"act:{i}", a["day"], a["day"], "cardio", a["name"], a["type"], a["minutes"],
             a["averageHR"], a["maxHR"], "vec", f"act:{i}", "x"))
    resting = _vector_resting()
    for day, value in resting.items():
        con.execute("INSERT INTO daily_metric(day, metric, value, source) VALUES (?,?,?,?)",
                    (day, "resting_hr", value, "vec"))
    ledger.compute(con)
    days = [dict(r) for r in con.execute(
        "SELECT day, tissue_id AS tissue, side, dose, sets, reps, acute, chronic"
        " FROM tissue_load_day WHERE dose > 0 OR day = (SELECT MAX(day) FROM tissue_load_day)"
        " ORDER BY day, tissue_id, side")]
    return {"note": "Synthetic. Written by `rehabit export-shared`; do not edit by hand.",
            "sets": sets, "steps": steps, "activities": activities, "restingHR": resting,
            "tissueDays": days}


def files() -> dict[Path, str]:
    dump = lambda data: json.dumps(data, indent=1) + "\n"
    return {LIBRARY: dump(library.export()), VECTORS: dump(ledger_vectors())}


def write() -> list[str]:
    out = []
    for path, text in files().items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        out.append(str(path))
    return out
