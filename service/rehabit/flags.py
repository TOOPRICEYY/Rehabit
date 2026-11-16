"""Named load, recovery and step flags. Each is a plain rule with a visible reason.

The flags describe a change in load ("this week is 1.8 times what this tissue has
recently seen"). They are not injury probabilities. Thresholds are starting values
held in Thresholds so the history replay can test them.
"""

from __future__ import annotations

import json
import sqlite3
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, timedelta

from .ledger import Settings, _d, reference_key, set_doses


@dataclass(frozen=True)
class Thresholds:
    spike_ratio: float = 1.5           # week against the mean of the previous four
    spike_min_prior_days: int = 2      # loaded days needed in those four weeks
    re_entry_days: int = 21            # unloaded this long, then loaded
    re_entry_period_days: int = 42     # how long after a re-entry the load still counts as new
    intensity_jump: float = 1.10       # load against the 28-day heaviest
    density_min_dose: float = 5.0      # effective reps that count as "loaded"
    cluster_days: int = 5              # loaded days ...
    cluster_window: int = 9            # ... within this many days
    freeze_sessions: int = 6           # sessions at one unchanged load ...
    freeze_span_days: int = 28         # ... spanning at least this long
    layoff_days: int = 7               # gap after which the load should step back
    compensation_ratio: float = 1.3    # other side's chronic load against onset
    session_jump: float = 1.5          # one session's minutes against the 28-day longest
    # Recovery and steps: the last 7 days against the 28 days before them.
    baseline_min_days: int = 14        # values needed in those 28 days
    recent_min_days: int = 4           # values needed in the last 7
    hrv_suppressed: float = 0.92       # 7-day mean HRV as a share of the baseline
    rhr_elevated_bpm: float = 3.0      # 7-day mean resting heart rate above the baseline
    short_sleep_minutes: float = 390   # a short night (6.5 hours) ...
    short_sleep_nights: int = 3        # ... this many times in 7
    step_spike: float = 1.5            # 7-day mean steps against the baseline
    step_day_jump: float = 1.5         # one day's steps against the 28-day highest


def _insert(con, day, kind, scope_type, scope, detail, side=None, value=None,
            threshold=None, exercise_id=None):
    con.execute(
        "INSERT INTO flag(day, kind, scope_type, scope, exercise_id, side, value, threshold, detail)"
        " VALUES (?,?,?,?,?,?,?,?,?)",
        (day.isoformat(), kind, scope_type, scope, exercise_id, side,
         None if value is None else round(value, 2), threshold, detail),
    )


def _tissue_flags(con, t: Thresholds) -> None:
    series: dict[tuple[str, str], dict[date, float]] = defaultdict(dict)
    for r in con.execute("SELECT day, tissue_id, side, dose FROM tissue_load_day"):
        series[(r["tissue_id"], r["side"])][_d(r["day"])] = r["dose"]
    for (tissue, side), by_day in series.items():
        days = sorted(by_day)
        loaded = [d for d in days if by_day[d] >= t.density_min_dose]
        loaded_set = set(loaded)
        any_load = [d for d in days if by_day[d] > 0]
        first_load = any_load[0] if any_load else None
        last_loaded = re_entered = None
        for d in any_load:
            dose = by_day[d]
            # Re-entry: nothing for three weeks, then load. The weeks after it are
            # flagged too, because tissue adapts more slowly than a routine settles.
            if last_loaded and (d - last_loaded).days >= t.re_entry_days:
                re_entered = d
                _insert(con, d, "re_entry", "tissue", tissue, side=side,
                        value=(d - last_loaded).days, threshold=t.re_entry_days,
                        detail=f"{tissue} ({side}) loaded after {(d - last_loaded).days} days with none")
            elif re_entered and (d - re_entered).days <= t.re_entry_period_days:
                _insert(con, d, "re_entry_period", "tissue", tissue, side=side,
                        value=(d - re_entered).days, threshold=t.re_entry_period_days,
                        detail=f"{tissue} ({side}) is {(d - re_entered).days} days into a return from a layoff")
            last_loaded = d
            # Spike: this week against the mean of the four weeks before it. The
            # earlier weeks exclude the current one, which avoids the built-in
            # correlation of the classic acute:chronic ratio.
            week = sum(by_day.get(d - timedelta(days=i), 0.0) for i in range(7))
            prior_days = [d - timedelta(days=i) for i in range(7, 35)]
            prior_total = sum(by_day.get(x, 0.0) for x in prior_days)
            prior_loaded = sum(1 for x in prior_days if by_day.get(x, 0.0) > 0)
            if (first_load and (d - first_load).days >= 34
                    and prior_loaded >= t.spike_min_prior_days and prior_total > 0):
                ratio = week / (prior_total / 4)
                if ratio > t.spike_ratio:
                    _insert(con, d, "spike", "tissue", tissue, side=side, value=ratio,
                            threshold=t.spike_ratio,
                            detail=f"{tissue} ({side}) week is {ratio:.2f} times the mean of the previous four")
            # Density: loaded on consecutive days, or many days in a short window.
            if dose >= t.density_min_dose:
                if (d - timedelta(days=1)) in loaded_set:
                    _insert(con, d, "density", "tissue", tissue, side=side, value=1, threshold=2,
                            detail=f"{tissue} ({side}) loaded again within 48 hours")
                in_window = sum(1 for i in range(t.cluster_window)
                                if (d - timedelta(days=i)) in loaded_set)
                if in_window >= t.cluster_days:
                    _insert(con, d, "density_cluster", "tissue", tissue, side=side,
                            value=in_window, threshold=t.cluster_days,
                            detail=f"{tissue} ({side}) loaded on {in_window} of the last {t.cluster_window} days")


def _exercise_flags(con, t: Thresholds, settings: Settings) -> None:
    by_key: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for rec in set_doses(con, settings):
        row = rec["row"]
        top = row["load_max_kg"] or row["load_kg"]
        if not top:
            continue
        key = reference_key(row)
        sessions = by_key[key]
        if sessions and sessions[-1]["day"] == rec["day"]:
            sessions[-1]["top"] = max(sessions[-1]["top"], top)
            sessions[-1]["reference"] = sessions[-1]["reference"] or rec["reference_kg"]
        else:
            sessions.append({"day": rec["day"], "top": top, "reference": rec["reference_kg"],
                             "name": row["source_exercise"], "exercise_id": row["exercise_id"],
                             "side": row["side"]})
    for sessions in by_key.values():
        for i, s in enumerate(sessions):
            common = dict(scope_type="exercise", scope=s["name"], side=s["side"],
                          exercise_id=s["exercise_id"])
            if s["reference"] and s["top"] > s["reference"] * t.intensity_jump:
                ratio = s["top"] / s["reference"]
                _insert(con, s["day"], "intensity_jump", value=ratio, threshold=t.intensity_jump,
                        detail=f"{s['name']} at {s['top'] / 0.45359237:.0f} lb, {ratio:.2f} times the 28-day heaviest",
                        **common)
            if i == 0:
                continue
            prev = sessions[i - 1]
            gap = (s["day"] - prev["day"]).days
            if gap >= t.layoff_days and s["top"] >= prev["top"] * 0.999:
                _insert(con, s["day"], "layoff_no_step_back", value=gap, threshold=t.layoff_days,
                        detail=f"{s['name']} resumed after {gap} days at the same or a heavier load",
                        **common)
            recent = [x for x in sessions[: i + 1] if (s["day"] - x["day"]).days <= 42]
            run = []
            for x in reversed(recent):
                if abs(x["top"] - s["top"]) <= 0.01 * s["top"]:
                    run.append(x)
                else:
                    break
            if (len(run) >= t.freeze_sessions
                    and (run[0]["day"] - run[-1]["day"]).days >= t.freeze_span_days):
                _insert(con, s["day"], "freeze", value=len(run), threshold=t.freeze_sessions,
                        detail=f"{s['name']} unchanged for {len(run)} sessions over {(run[0]['day'] - run[-1]['day']).days} days",
                        **common)


def _activity_flags(con, t: Thresholds) -> None:
    by_type: dict[str, list[tuple[date, float]]] = defaultdict(list)
    for r in con.execute(
        "SELECT day, activity_type, minutes FROM session"
        " WHERE kind != 'gym' AND activity_type IS NOT NULL ORDER BY start"
    ):
        by_type[r["activity_type"]].append((_d(r["day"]), r["minutes"] or 0.0))
    # The record of activities starts with the first one of any type, which may be
    # years after the first gym log.
    span = con.execute("SELECT MIN(day) FROM session WHERE kind != 'gym'").fetchone()[0]
    data_start = _d(span) if span else None
    for activity, sessions in by_type.items():
        re_entered = None
        for i, (d, minutes) in enumerate(sessions):
            earlier = sessions[:i]
            last = earlier[-1][0] if earlier else None
            gap = (d - last).days if last else (d - data_start).days
            if gap >= t.re_entry_days:
                re_entered = d
                what = f"after {gap} days with none" if last else f"with none in the {gap} days of record before it"
                _insert(con, d, "re_entry", "activity", activity, value=gap,
                        threshold=t.re_entry_days, detail=f"{activity} {what}")
            elif re_entered and 0 < (d - re_entered).days <= t.re_entry_period_days:
                _insert(con, d, "re_entry_period", "activity", activity,
                        value=(d - re_entered).days, threshold=t.re_entry_period_days,
                        detail=f"{activity} is {(d - re_entered).days} days into a return from a layoff")
            week = sum(m for x, m in sessions[: i + 1] if 0 <= (d - x).days < 7)
            prior = sum(m for x, m in earlier if 7 <= (d - x).days < 35)
            if prior > 0 and week / (prior / 4) > t.spike_ratio:
                ratio = week / (prior / 4)
                _insert(con, d, "spike", "activity", activity, value=ratio, threshold=t.spike_ratio,
                        detail=f"{activity} week of {week:.0f} min is {ratio:.2f} times the mean of the previous four")
            longest = max((m for x, m in earlier if 0 < (d - x).days <= 28), default=0.0)
            if longest > 0 and minutes > longest * t.session_jump:
                _insert(con, d, "session_jump", "activity", activity, value=minutes / longest,
                        threshold=t.session_jump,
                        detail=f"{activity} session of {minutes:.0f} min against a 28-day longest of {longest:.0f}")


def _compensation_flags(con, t: Thresholds) -> None:
    opposite = {"left": "right", "right": "left"}
    for inj in con.execute("SELECT * FROM injury"):
        if inj["side"] not in opposite:
            continue
        other = opposite[inj["side"]]
        onset = _d(inj["onset"])
        for tissue in json.loads(inj["tissues"]):
            rows = con.execute(
                "SELECT day, dose, chronic FROM tissue_load_day WHERE tissue_id = ? AND side = ?"
                " AND day >= ? ORDER BY day", (tissue, other, onset.isoformat())).fetchall()
            if not rows or rows[0]["chronic"] <= 0:
                continue
            base = rows[0]["chronic"]
            for r in rows:
                if r["dose"] > 0 and r["chronic"] > base * t.compensation_ratio:
                    _insert(con, _d(r["day"]), "compensation", "tissue", tissue, side=other,
                            value=r["chronic"] / base, threshold=t.compensation_ratio,
                            detail=f"{tissue} ({other}) carries {r['chronic'] / base:.2f} times its load at the onset of {inj['label']}")


def _metric(con, metric: str) -> dict[date, float]:
    # One value per day; if two sources report the same day, the mean.
    return {_d(r["day"]): r["v"] for r in con.execute(
        "SELECT day, AVG(value) AS v FROM daily_metric WHERE metric = ? GROUP BY day", (metric,))}


def _recent_and_baseline(series: dict[date, float], d: date, t: Thresholds):
    """Mean of the last 7 days and of the 28 before them, or None if too sparse.

    The baseline excludes the current week, so a bad week is compared with what
    came before it and not partly with itself. It also moves with the season, a
    change of medication or a new watch, which a fixed all-time mean would not.
    """
    recent = [series[x] for i in range(7) if (x := d - timedelta(days=i)) in series]
    prior = [series[x] for i in range(7, 35) if (x := d - timedelta(days=i)) in series]
    if len(recent) < t.recent_min_days or len(prior) < t.baseline_min_days:
        return None
    return sum(recent) / len(recent), sum(prior) / len(prior), prior


def _recovery_flags(con, t: Thresholds) -> None:
    hrv, rhr, sleep = _metric(con, "hrv_ms"), _metric(con, "resting_hr"), _metric(con, "sleep_minutes")
    low_days: dict[date, str] = {}
    for d in sorted(hrv):
        got = _recent_and_baseline(hrv, d, t)
        if got and got[0] / got[1] < t.hrv_suppressed:
            detail = f"7-day HRV of {got[0]:.0f} ms is {got[0] / got[1]:.2f} of the previous four weeks ({got[1]:.0f} ms)"
            _insert(con, d, "hrv_suppressed", "recovery", "hrv_ms", detail,
                    value=got[0] / got[1], threshold=t.hrv_suppressed)
            low_days[d] = detail
    for d in sorted(rhr):
        got = _recent_and_baseline(rhr, d, t)
        if got and got[0] - got[1] >= t.rhr_elevated_bpm:
            detail = f"7-day resting heart rate of {got[0]:.0f} is {got[0] - got[1]:.1f} above the previous four weeks ({got[1]:.0f})"
            _insert(con, d, "rhr_elevated", "recovery", "resting_hr", detail,
                    value=got[0] - got[1], threshold=t.rhr_elevated_bpm)
            low_days.setdefault(d, detail)
    for d in sorted(sleep):
        nights = [sleep[x] for i in range(7) if (x := d - timedelta(days=i)) in sleep]
        short = sum(1 for n in nights if n < t.short_sleep_minutes)
        if len(nights) >= t.recent_min_days and short >= t.short_sleep_nights:
            _insert(con, d, "short_sleep", "recovery", "sleep_minutes",
                    f"{short} of the last {len(nights)} nights under {t.short_sleep_minutes / 60:.1f} hours",
                    value=short, threshold=t.short_sleep_nights)
    # Training on a day when recovery was already down: the two together are the
    # claim worth testing, since either alone is common.
    for r in con.execute("SELECT day, COUNT(*) AS n FROM session GROUP BY day"):
        d = _d(r["day"])
        if d in low_days:
            _insert(con, d, "load_on_low_recovery", "recovery", "session",
                    f"trained while {low_days[d]}", value=r["n"])


def _step_flags(con, t: Thresholds) -> None:
    steps = _metric(con, "steps")
    for d in sorted(steps):
        got = _recent_and_baseline(steps, d, t)
        if not got:
            continue
        recent, base, prior = got
        if recent / base > t.step_spike:
            _insert(con, d, "step_spike", "steps", "steps", value=recent / base, threshold=t.step_spike,
                    detail=f"7-day steps of {recent:.0f} a day are {recent / base:.2f} times the previous four weeks ({base:.0f})")
        highest = max(prior + [steps[x] for i in range(1, 7) if (x := d - timedelta(days=i)) in steps])
        if steps[d] > highest * t.step_day_jump:
            _insert(con, d, "step_day_jump", "steps", "steps", value=steps[d] / highest,
                    threshold=t.step_day_jump,
                    detail=f"{steps[d]:.0f} steps against a highest of {highest:.0f} in the five weeks before")


def compute(con: sqlite3.Connection, thresholds: Thresholds = Thresholds(),
            settings: Settings = Settings()) -> dict:
    """Rebuild the flag table. Run ledger.compute first."""
    con.execute("DELETE FROM flag")
    _tissue_flags(con, thresholds)
    _exercise_flags(con, thresholds, settings)
    _activity_flags(con, thresholds)
    _compensation_flags(con, thresholds)
    _recovery_flags(con, thresholds)
    _step_flags(con, thresholds)
    con.commit()
    return {r["kind"]: r["n"] for r in con.execute(
        "SELECT kind, COUNT(*) AS n FROM flag GROUP BY kind ORDER BY kind")}
