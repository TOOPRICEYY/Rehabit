"""Tissue load ledger: turn logged sets into a daily dose per tissue and side.

    dose = share x n x (load / reference load) ^ k

n is reps, or hold seconds / 5 for an isometric hold. The reference load is the
heaviest load used for that exercise and side in the previous 28 days, so the
ratio is 1 at the usual weight and rises steeply above it. k (default 2) makes a
heavier load cost more than the same percentage of extra reps. At the usual
weight a dose reads as "effective reps" for that tissue.

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


SIDES = {"left": ("left",), "right": ("right",), "both": ("left", "right")}


def _d(text: str) -> date:
    return date.fromisoformat(text)


def reference_key(row: sqlite3.Row | dict) -> tuple[str, str]:
    """Loads are compared within one source's naming of one exercise on one side."""
    return (f"{row['source']}|{row['source_exercise'].strip().lower()}", row["side"])


def effective_reps(row: sqlite3.Row | dict, settings: Settings) -> float:
    if row["kind"] == "hold":
        return (row["hold_seconds"] or 0) * (row["set_count"] or 1) / settings.hold_seconds_per_rep
    return row["reps"] or 0


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
        if load and reference:
            ratio = min(settings.max_ratio, max(settings.min_ratio, load / reference))
        n = effective_reps(row, settings)
        out.append({
            "row": row, "day": day, "reference_kg": reference, "ratio": ratio,
            "effective_reps": n, "dose": n * ratio ** settings.intensity_exponent,
        })
        top = row["load_max_kg"] or load
        if top:
            pending.append((key, day, top))
    return out


def compute(con: sqlite3.Connection, settings: Settings = Settings()) -> dict:
    """Rebuild tissue_load_day from set_entry."""
    links: dict[str, list[tuple[str, float, str]]] = defaultdict(list)
    for r in con.execute("SELECT exercise_id, tissue_id, share, role FROM exercise_tissue"):
        links[r["exercise_id"]].append((r["tissue_id"], r["share"], r["role"]))

    daily: dict[tuple[str, str], dict[date, list[float]]] = defaultdict(lambda: defaultdict(lambda: [0.0, 0.0, 0.0]))
    doses = set_doses(con, settings)
    for rec in doses:
        row = rec["row"]
        for tissue_id, share, role in links.get(row["exercise_id"], []):
            for side in SIDES[row["side"]]:
                cell = daily[(tissue_id, side)][rec["day"]]
                cell[0] += share * rec["dose"]
                if role == "prime":
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
        acute = chronic = 0.0
        day = first
        while day <= last:
            dose, sets, reps = by_day.get(day, (0.0, 0.0, 0.0))
            acute = acute * decay_a + dose * (1 - decay_a)
            chronic = chronic * decay_c + dose * (1 - decay_c)
            con.execute(
                "INSERT INTO tissue_load_day(day, tissue_id, side, dose, sets, reps, acute, chronic)"
                " VALUES (?,?,?,?,?,?,?,?)",
                (day.isoformat(), tissue_id, side, round(dose, 3), sets, reps,
                 round(acute, 4), round(chronic, 4)),
            )
            written += 1
            day += timedelta(days=1)
    con.commit()
    return {"days": (last - first).days + 1, "tissue_sides": len(daily), "rows": written}
