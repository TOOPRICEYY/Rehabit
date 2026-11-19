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

Recorded activities (a ride, a row, a run) count as one "set" of their own
pattern on both sides:

    effective reps = minutes x rate(type) x intensity

`rate` is effective reps per minute at a moderate effort (`library.ACTIVITIES`,
where each is worked out). For an activity whose steps are already in the daily
step count, the rate holds only what it adds beyond those steps. `intensity` is
the heart-rate reserve used, (average - resting) / (max - resting), divided by
the reserve of a moderate effort (0.5) and kept between 0.5 and 2. It is 1 when
any of the three heart rates is unknown. It is linear, not squared like a load
ratio: heart rate measures the whole body's work, part of a harder effort goes
into a faster cadence rather than a harder stroke, and heat or a poor night
raise it with no extra load. An activity type with no rate adds nothing.

Every number here is a starting value chosen for the design, not a measured
constant. They live in Settings so the replay can test alternatives.
"""

from __future__ import annotations

import math
import sqlite3
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, timedelta

from . import library


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
    count_activities: bool = True
    # Heart-rate reserve of the moderate effort each activity rate is set at.
    activity_reference_reserve: float = 0.5
    activity_intensity_min: float = 0.5
    activity_intensity_max: float = 2.0
    # The highest heart rate seen is only trusted as the maximum after this many
    # recordings, and only when it is this far above the resting rate.
    activity_min_hr_recordings: int = 5
    activity_min_hr_range: float = 40.0
    activity_max_minutes: float = 600.0


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


def activity_intensity(avg_hr: float | None, resting_hr: float | None, max_hr: float | None,
                       settings: Settings = Settings()) -> float:
    """How hard an activity was against a moderate effort, from heart-rate reserve.
    1 when any of the three is unknown or they do not make sense together."""
    if not all(isinstance(v, (int, float)) and math.isfinite(v) and v > 0 for v in (avg_hr, resting_hr, max_hr)):
        return 1.0
    if max_hr - resting_hr < settings.activity_min_hr_range or settings.activity_reference_reserve <= 0:
        return 1.0
    reserve = (avg_hr - resting_hr) / (max_hr - resting_hr)
    return min(settings.activity_intensity_max,
               max(settings.activity_intensity_min, reserve / settings.activity_reference_reserve))


def activity_reps(pattern: str | None, minutes: float | None, intensity: float,
                  settings: Settings = Settings()) -> float:
    """Effective reps of one recorded activity on a tissue with share 1."""
    rate = library.ACTIVITIES.get(pattern or "")
    if not rate or not isinstance(minutes, (int, float)) or not math.isfinite(minutes) or minutes <= 0:
        return 0.0
    return min(minutes, settings.activity_max_minutes) * rate * intensity


def usual_resting_hr(resting: dict[date, float], day: date) -> float | None:
    """The median resting heart rate of the 28 days up to and including `day`."""
    values = [v for d, v in resting.items() if 0 <= (day - d).days <= 28]
    return _median(values) if values else None


def observed_max_hr(values: list[float], settings: Settings = Settings()) -> float | None:
    """The highest heart rate recorded, once there are enough recordings to trust it."""
    seen = [v for v in values if isinstance(v, (int, float)) and math.isfinite(v) and v > 0]
    return max(seen) if len(seen) >= settings.activity_min_hr_recordings else None


def activity_doses(con: sqlite3.Connection, settings: Settings = Settings()) -> list[dict]:
    """One record per recorded activity whose type has a rate."""
    resting = {_d(r[0]): r[1] for r in con.execute(
        "SELECT day, MIN(value) FROM daily_metric WHERE metric = 'resting_hr' AND value > 0 GROUP BY day")}
    top = observed_max_hr([r[0] for r in con.execute(
        "SELECT max_hr FROM session WHERE max_hr IS NOT NULL")], settings)
    out = []
    for r in con.execute(
            "SELECT day, activity_type, title, minutes, avg_hr, counts_as FROM session"
            " WHERE activity_type IS NOT NULL OR counts_as IS NOT NULL ORDER BY day, start, id"):
        # What the person said it was wins over what the type and name suggest;
        # an answer that is no activity pattern ("none") means no load.
        chosen = r["counts_as"]
        if chosen:
            pattern = chosen if chosen in library.ACTIVITIES else None
        else:
            pattern = library.match_activity(r["activity_type"], r["title"])
        day = _d(r["day"])
        intensity = activity_intensity(r["avg_hr"], usual_resting_hr(resting, day), top, settings)
        reps = activity_reps(pattern, r["minutes"], intensity, settings)
        if reps > 0:
            out.append({"row": {"exercise_id": pattern, "side": "both", "set_count": 1},
                        "day": day, "reference_kg": None, "ratio": 1.0, "intensity": intensity,
                        "effective_reps": reps, "dose": reps})
    return out


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
    if settings.count_activities:
        doses.extend(activity_doses(con, settings))
    for rec in doses:
        row = rec["row"]
        for tissue_id, share, role in links.get(row["exercise_id"], []):
            for side in SIDES[row["side"]]:
                cell = daily[(tissue_id, side)][rec["day"]]
                cell[0] += share * rec["dose"]
                if row["exercise_id"] == WALKING:
                    cell[3] += share * rec["dose"]
                elif role == "prime" and row["exercise_id"] not in library.ACTIVITIES:
                    # walking and recorded activities have no sets or reps to count
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
