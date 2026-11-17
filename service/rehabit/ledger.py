"""Tissue load ledger: turn logged sets into a daily dose per tissue and side.

    dose = share x n x (load / reference load) ^ k

n is reps, or hold seconds / 5 for an isometric hold. The reference load is the
heaviest load used for that exercise and side in the previous 28 days, so the
ratio is 1 at the usual weight and rises steeply above it. k (default 2) makes a
heavier load cost more than the same percentage of extra reps. At the usual
weight a dose reads as "effective reps" for that tissue.

Daily steps count too, as the "walking" pattern: each leg takes half the
steps, and every `steps_per_effective_rep` steps on a leg count as one
effective rep at usual weight. A step loads the calf about as hard as walking
does every day, far below a working set, so many steps make one rep. Days the
watch was not worn are filled with the median of the 28 days before, and the
28 days before the first reading with the median of the first 28 readings, so
the start of the step record and a day off the wrist do not read as a change
in load. The same rules run on the phone (`Ledger.walkingSets`).

Every number here is a starting value chosen for the design, not a measured
constant. They live in Settings so the replay can test alternatives.
"""

from __future__ import annotations

import math
import sqlite3
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, timedelta


@dataclass(frozen=True)
class Settings:
    intensity_exponent: float = 2.0
    hold_seconds_per_rep: float = 5.0
    reference_window_days: int = 28
    acute_days: float = 7.0
    chronic_days: float = 28.0
    min_ratio: float = 0.25
    max_ratio: float = 3.0
    steps_per_effective_rep: float = 100.0   # per leg
    count_steps: bool = True


WALKING = "walking"
WALKING_NAME = "Walking (daily steps)"


def _median(values: list[float]) -> float:
    v = sorted(values)
    m = len(v) // 2
    return v[m] if len(v) % 2 else (v[m - 1] + v[m]) / 2


def walking_reps(steps: dict[date, float], settings: Settings = Settings()) -> dict[date, float]:
    """Effective reps per leg for each day, from daily step counts (several
    sources already reduced to the largest reading of each day)."""
    readings = {d: v for d, v in steps.items() if v and v > 0 and math.isfinite(v)}
    if not readings or settings.steps_per_effective_rep <= 0:
        return {}
    first, last = min(readings), max(readings)
    warm = _median([v for d, v in readings.items() if (d - first).days < 28])
    out = {}
    day = first - timedelta(days=28)
    while day <= last:
        if day in readings:
            value = readings[day]
        elif day < first:
            value = warm
        else:
            before = [readings[day - timedelta(days=i)] for i in range(1, 29) if day - timedelta(days=i) in readings]
            value = _median(before) if before else warm
        out[day] = value / 2 / settings.steps_per_effective_rep
        day += timedelta(days=1)
    return out


def daily_steps(con: sqlite3.Connection) -> dict[date, float]:
    """The largest step count any source gave for each day. Phone and watch
    count the same walking, so they are never added."""
    return {_d(r[0]): r[1] for r in con.execute(
        "SELECT day, MAX(value) FROM daily_metric WHERE metric = 'steps' AND value > 0 GROUP BY day")}


SIDES = {"left": ("left",), "right": ("right",), "both": ("left", "right")}


def _d(text: str) -> date:
    return date.fromisoformat(text)


def reference_key(row: sqlite3.Row | dict) -> tuple[str, str]:
    """Loads are compared within one source's naming of one exercise on one side."""
    return (f"{row['source']}|{row['source_exercise'].strip().lower()}", row["side"])


def effective_reps(row: sqlite3.Row | dict, settings: Settings) -> float:
    # A mistyped negative number must not subtract load.
    if row["kind"] == "hold":
        return max(0.0, (row["hold_seconds"] or 0) * (row["set_count"] or 1) / settings.hold_seconds_per_rep)
    return max(0.0, row["reps"] or 0)


def set_doses(con: sqlite3.Connection, settings: Settings = Settings()) -> list[dict]:
    """One record per mapped set row: its reference load, ratio and base dose."""
    rows = con.execute(
        "SELECT * FROM set_entry WHERE exercise_id IS NOT NULL ORDER BY day, session_id, position"
    ).fetchall()
    history: dict[tuple[str, str], list[tuple[date, float]]] = defaultdict(list)
    out = []
    pending: list[tuple[tuple[str, str], date, float]] = []
    current_day = None
    for row in rows:
        day = _d(row["day"])
        if day != current_day:
            # Loads from one day only become history once the day is over, so a
            # heavy set never lowers the ratio of the sets around it.
            for key, d, load in pending:
                history[key].append((d, load))
            pending, current_day = [], day
        key = reference_key(row)
        window_start = day - timedelta(days=settings.reference_window_days)
        prior = [load for d, load in history[key] if window_start <= d < day]
        reference = max(prior) if prior else None
        load = row["load_kg"]
        ratio = 1.0
        if load and load > 0 and reference:
            ratio = min(settings.max_ratio, max(settings.min_ratio, load / reference))
        n = effective_reps(row, settings)
        out.append({
            "row": row, "day": day, "reference_kg": reference, "ratio": ratio,
            "effective_reps": n, "dose": n * ratio ** settings.intensity_exponent,
        })
        top = row["load_max_kg"] or load
        if top and top > 0:      # a negative or zero load never becomes the reference
            pending.append((key, day, top))
    return out


def compute(con: sqlite3.Connection, settings: Settings = Settings()) -> dict:
    """Rebuild tissue_load_day from set_entry."""
    links: dict[str, list[tuple[str, float, str]]] = defaultdict(list)
    for r in con.execute("SELECT exercise_id, tissue_id, share, role FROM exercise_tissue"):
        links[r["exercise_id"]].append((r["tissue_id"], r["share"], r["role"]))

    daily: dict[tuple[str, str], dict[date, list[float]]] = defaultdict(lambda: defaultdict(lambda: [0.0, 0.0, 0.0, 0.0]))
    doses = set_doses(con, settings)
    if settings.count_steps:
        for day, reps in sorted(walking_reps(daily_steps(con), settings).items()):
            doses.append({"row": {"exercise_id": WALKING, "side": "both", "set_count": 1},
                          "day": day, "reference_kg": None, "ratio": 1.0,
                          "effective_reps": reps, "dose": reps})
    for rec in doses:
        row = rec["row"]
        for tissue_id, share, role in links.get(row["exercise_id"], []):
            for side in SIDES[row["side"]]:
                cell = daily[(tissue_id, side)][rec["day"]]
                cell[0] += share * rec["dose"]
                if row["exercise_id"] == WALKING:
                    cell[3] += share * rec["dose"]
                elif role == "prime":   # walking has no sets or reps to count
                    cell[1] += row["set_count"] or 1
                    cell[2] += rec["effective_reps"]

    con.execute("DELETE FROM tissue_load_day")
    if not doses:
        con.commit()
        return {"days": 0, "tissue_sides": 0}
    first = min(rec["day"] for rec in doses)
    last = max(rec["day"] for rec in doses)
    decay_a = math.exp(-1 / settings.acute_days)
    decay_c = math.exp(-1 / settings.chronic_days)
    written = 0
    for (tissue_id, side), by_day in daily.items():
        acute = chronic = walking_chronic = 0.0
        day = first
        while day <= last:
            dose, sets, reps, walking = by_day.get(day, (0.0, 0.0, 0.0, 0.0))
            acute = acute * decay_a + dose * (1 - decay_a)
            chronic = chronic * decay_c + dose * (1 - decay_c)
            walking_chronic = walking_chronic * decay_c + walking * (1 - decay_c)
            con.execute(
                "INSERT INTO tissue_load_day(day, tissue_id, side, dose, sets, reps, acute, chronic,"
                " walking_dose, walking_chronic) VALUES (?,?,?,?,?,?,?,?,?,?)",
                (day.isoformat(), tissue_id, side, round(dose, 3), sets, reps,
                 round(acute, 4), round(chronic, 4), round(walking, 3), round(walking_chronic, 4)),
            )
            written += 1
            day += timedelta(days=1)
    con.commit()
    return {"days": (last - first).days + 1, "tissue_sides": len(daily), "rows": written}
