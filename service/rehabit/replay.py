"""Replay check: did the flags fire in the run-up to each known injury, and how
often do they fire anyway?

A flag that fires before an injury means little if it fires in most fortnights.
So every count is shown beside its base rate: the share of all windows of the
same length, across the whole record, that contain the same kind of flag for the
same tissues and activities.
"""

from __future__ import annotations

import json
import sqlite3
from datetime import date, timedelta

from .ledger import _d

SLACK_DAYS = {"day": 0, "week": 7, "month": 15}
MIN_SHARE = 0.25
KINDS = ["spike", "re_entry", "re_entry_period", "intensity_jump", "density", "density_cluster",
         "layoff_no_step_back", "session_jump", "freeze"]


def _relevant_flags(con: sqlite3.Connection, injury: sqlite3.Row) -> list[dict]:
    tissues = json.loads(injury["tissues"])
    activities = json.loads(injury["activity_types"])
    exercises = set()
    for tissue in tissues:
        for r in con.execute(
            "SELECT exercise_id FROM exercise_tissue WHERE tissue_id = ? AND share >= ?",
            (tissue, MIN_SHARE),
        ):
            exercises.add(r["exercise_id"])
    out = []
    for f in con.execute("SELECT * FROM flag WHERE kind != 'compensation' ORDER BY day"):
        if f["scope_type"] == "tissue":
            keep = f["scope"] in tissues and f["side"] == injury["side"]
        elif f["scope_type"] == "exercise":
            keep = f["exercise_id"] in exercises and f["side"] in (injury["side"], "both")
        else:
            keep = f["scope"] in activities
        if keep:
            out.append(dict(f))
    return out


def replay(con: sqlite3.Connection, lookback_days: int = 14) -> list[dict]:
    span = con.execute("SELECT MIN(day), MAX(day) FROM session").fetchone()
    if not span[0]:
        return []
    data_start, data_end = _d(span[0]), _d(span[1])
    active_days = {_d(r[0]) for r in con.execute("SELECT DISTINCT day FROM session")}
    results = []
    for injury in con.execute("SELECT * FROM injury ORDER BY onset"):
        onset = _d(injury["onset"])
        length = lookback_days + SLACK_DAYS.get(injury["onset_precision"], 0)
        start = onset - timedelta(days=length)
        flags = _relevant_flags(con, injury)
        by_day: dict[date, set[str]] = {}
        for f in flags:
            by_day.setdefault(_d(f["day"]), set()).add(f["kind"])

        # Comparison windows: every week of the record in which training happened.
        # Idle stretches are left out, or they would make every flag look rare.
        windows = []
        w_end = data_start + timedelta(days=35 + length)
        while w_end <= data_end:
            days = [w_end - timedelta(days=i) for i in range(length + 1)]
            if any(d in active_days for d in days):
                kinds = set()
                for d in days:
                    kinds |= by_day.get(d, set())
                windows.append(kinds)
            w_end += timedelta(days=7)

        in_window = [f for f in flags if start <= _d(f["day"]) <= onset]
        kinds = {}
        for kind in KINDS:
            hits = [f for f in in_window if f["kind"] == kind]
            base = (sum(1 for w in windows if kind in w) / len(windows)) if windows else None
            kinds[kind] = {"count": len(hits), "base_rate": base}
        any_base = (sum(1 for w in windows if w) / len(windows)) if windows else None
        results.append({
            "comparison_windows": len(windows),
            "injury": injury["label"], "side": injury["side"], "onset": injury["onset"],
            "onset_precision": injury["onset_precision"],
            "window": [start.isoformat(), onset.isoformat()],
            "covered": start >= data_start,
            "kinds": kinds, "any_flag_base_rate": any_base,
            "flags": [{"day": f["day"], "kind": f["kind"], "detail": f["detail"]} for f in in_window],
        })
    return results


def format_report(results: list[dict]) -> str:
    lines = []
    for r in results:
        lines.append(f"\n{r['injury']} ({r['side']}), onset {r['onset']} (to the {r['onset_precision']})")
        lines.append(f"  window {r['window'][0]} to {r['window'][1]}, compared with {r['comparison_windows']} training windows"
                     + ("" if r["covered"] else "  [starts before the record does]"))
        fired = [(k, v) for k, v in r["kinds"].items() if v["count"]]
        if not fired:
            lines.append("  no relevant flag fired in the window")
        if r["any_flag_base_rate"] is not None:
            lines.append(f"  any relevant flag: base rate {r['any_flag_base_rate']:.0%} of windows")
        for kind, v in fired:
            base = "n/a" if v["base_rate"] is None else f"{v['base_rate']:.0%}"
            lines.append(f"  {kind:<20} fired {v['count']:>2} times   base rate {base} of windows")
        quiet = [k for k, v in r["kinds"].items() if not v["count"]]
        if fired and quiet:
            lines.append("  did not fire: " + ", ".join(quiet))
        for f in r["flags"][:12]:
            lines.append(f"    {f['day']}  {f['kind']}: {f['detail']}")
        if len(r["flags"]) > 12:
            lines.append(f"    ... and {len(r['flags']) - 12} more")
    return "\n".join(lines)
