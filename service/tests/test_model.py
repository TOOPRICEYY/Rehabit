"""Ledger, flags, replay and the read-only tools, on small synthetic histories."""

from datetime import date, timedelta

import pytest

from rehabit import db, flags, ledger, replay
from rehabit.mcp_server import TOOL_NAMES, Tools
from rehabit.profile import seed_injuries

START = date(2025, 1, 6)


def add_set(con, day, exercise_id="press_horizontal", name="Bench Press", load_kg=40.0,
            reps=10, side="both", kind="reps", hold_seconds=None, source="test"):
    day_s = day.isoformat()
    session_id = f"{source}:{day_s}"
    con.execute(
        "INSERT OR IGNORE INTO session(id, start, day, kind, title, source, source_id, imported_at)"
        " VALUES (?,?,?,?,?,?,?,?)",
        (session_id, f"{day_s} 10:00", day_s, "gym", "Session", source, session_id, db.now()))
    position = con.execute("SELECT COUNT(*) FROM set_entry WHERE session_id = ?",
                           (session_id,)).fetchone()[0]
    con.execute(
        "INSERT INTO set_entry(id, session_id, day, position, exercise_id, source_exercise,"
        " granularity, side, kind, reps, hold_seconds, load_kg, load_max_kg, source)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (f"{session_id}:{position}", session_id, day_s, position, exercise_id, name, "set",
         side, kind, None if kind == "hold" else reps, hold_seconds, load_kg, load_kg, source))


def add_activity(con, day, minutes, activity_type="running"):
    day_s = day.isoformat()
    session_id = f"act:{activity_type}:{day_s}"
    con.execute(
        "INSERT INTO session(id, start, day, kind, activity_type, minutes, source, source_id,"
        " imported_at) VALUES (?,?,?,?,?,?,?,?,?)",
        (session_id, f"{day_s} 08:00", day_s, "cardio", activity_type, minutes, "test",
         session_id, db.now()))


def dose(con, tissue, side, day):
    row = con.execute("SELECT dose FROM tissue_load_day WHERE tissue_id = ? AND side = ? AND day = ?",
                      (tissue, side, day.isoformat())).fetchone()
    return row["dose"] if row else 0.0


def kinds(con, **where):
    sql = "SELECT day, kind FROM flag WHERE 1=1" + "".join(f" AND {k} = ?" for k in where)
    return {(r["day"], r["kind"]) for r in con.execute(sql, tuple(where.values()))}


def test_dose_is_share_times_reps_at_the_usual_load(con):
    add_set(con, START)
    ledger.compute(con)
    assert dose(con, "pec_major", "left", START) == pytest.approx(10.0)    # prime, share 1.0
    assert dose(con, "pec_major", "right", START) == pytest.approx(10.0)   # 'both' loads each side
    assert dose(con, "triceps", "left", START) == pytest.approx(5.0)       # assist, share 0.5


def test_heavier_load_costs_the_square_of_the_ratio(con):
    add_set(con, START, load_kg=40.0)
    add_set(con, START + timedelta(days=3), load_kg=48.0)                  # 1.2 times
    ledger.compute(con)
    assert dose(con, "pec_major", "left", START + timedelta(days=3)) == pytest.approx(10 * 1.2 ** 2)


def test_same_day_sets_do_not_change_each_others_reference(con):
    add_set(con, START, load_kg=40.0)
    day = START + timedelta(days=3)
    add_set(con, day, load_kg=60.0)                                        # 1.5 times
    add_set(con, day, load_kg=40.0)                                        # still judged against 40
    ledger.compute(con)
    assert dose(con, "pec_major", "left", day) == pytest.approx(10 * 1.5 ** 2 + 10)


def test_hold_counts_five_seconds_as_one_rep_and_side_is_kept(con):
    add_set(con, START, exercise_id="leg_extension", name="Leg Extension", side="right",
            kind="hold", hold_seconds=45)
    ledger.compute(con)
    assert dose(con, "quads", "right", START) == pytest.approx(9.0)
    assert dose(con, "quads", "left", START) == 0.0


def test_intensity_jump_and_layoff_flags(con):
    add_set(con, START, load_kg=40.0)
    add_set(con, START + timedelta(days=3), load_kg=42.0)                  # 5 percent, under the rule
    add_set(con, START + timedelta(days=13), load_kg=50.0)                 # 19 percent, after 10 days
    ledger.compute(con)
    flags.compute(con)
    found = kinds(con, scope_type="exercise")
    jump_day = (START + timedelta(days=13)).isoformat()
    assert (jump_day, "intensity_jump") in found
    assert (jump_day, "layoff_no_step_back") in found
    assert ((START + timedelta(days=3)).isoformat(), "intensity_jump") not in found


def test_re_entry_then_re_entry_period(con):
    add_set(con, START)
    back = START + timedelta(days=30)
    add_set(con, back)
    add_set(con, back + timedelta(days=10))
    add_set(con, back + timedelta(days=50))
    ledger.compute(con)
    flags.compute(con)
    found = kinds(con, scope="pec_major", side="left")
    assert (back.isoformat(), "re_entry") in found
    assert ((back + timedelta(days=10)).isoformat(), "re_entry_period") in found
    assert ((back + timedelta(days=50)).isoformat(), "re_entry_period") not in found


def test_spike_needs_its_own_history_and_fires_on_a_big_week(con):
    for _ in range(4):                                                     # big, but nothing to judge it by yet
        add_set(con, START + timedelta(days=7 * 6))
    for week in range(60):                                                 # otherwise steady: once a week
        add_set(con, START + timedelta(days=7 * week))
    big = START + timedelta(days=7 * 60)
    for _ in range(4):                                                     # four times the usual week
        add_set(con, big)
    ledger.compute(con)
    flags.compute(con)
    spikes = {d for d, k in kinds(con, scope="pec_major", side="left") if k == "spike"}
    assert spikes == {big.isoformat()}


def test_density_and_cluster(con):
    for i in range(5):
        add_set(con, START + timedelta(days=i))
    ledger.compute(con)
    flags.compute(con)
    found = kinds(con, scope="pec_major", side="left")
    assert (START.isoformat(), "density") not in found
    assert ((START + timedelta(days=1)).isoformat(), "density") in found
    assert ((START + timedelta(days=4)).isoformat(), "density_cluster") in found
    assert ((START + timedelta(days=3)).isoformat(), "density_cluster") not in found


def test_activity_session_jump(con):
    add_activity(con, START, 20)
    add_activity(con, START + timedelta(days=7), 25)
    add_activity(con, START + timedelta(days=14), 60)
    ledger.compute(con)
    flags.compute(con)
    found = kinds(con, scope_type="activity")
    assert ((START + timedelta(days=14)).isoformat(), "session_jump") in found
    assert ((START + timedelta(days=7)).isoformat(), "session_jump") not in found


def test_replay_reports_flags_before_the_onset_with_a_base_rate(con, profile):
    seed_injuries(con, profile)                                            # left pec, 2025-03-10
    onset = date(2025, 3, 10)
    for week in range(1, 9):
        add_set(con, onset - timedelta(days=7 * week))
    for i in range(1, 6):                                                  # five days running before it
        add_set(con, onset - timedelta(days=i))
    ledger.compute(con)
    flags.compute(con)
    result = replay.replay(con, lookback_days=14)
    assert len(result) == 1
    text = replay.format_report(result)
    assert "Left pec strain" in text and "density_cluster" in text


def test_tools_are_read_only(con, tmp_path):
    add_set(con, START)
    ledger.compute(con)
    flags.compute(con)
    con.close()
    tools = Tools(str(tmp_path / "test.db"))
    assert all(hasattr(tools, name) for name in TOOL_NAMES)
    assert tools.run_query("SELECT COUNT(*) AS n FROM set_entry")[0]["n"] == 1
    for sql in ("DELETE FROM set_entry", "SELECT 1; DELETE FROM set_entry",
                "UPDATE set_entry SET reps = 0"):
        assert "error" in tools.run_query(sql)
    assert tools.run_query("SELECT COUNT(*) AS n FROM set_entry")[0]["n"] == 1
    load = tools.get_tissue_load("pec_major", "left", START.isoformat(), START.isoformat())
    assert load and "dose" in str(load)


def add_metric(con, day, metric, value):
    con.execute("INSERT INTO daily_metric(day, metric, value, unit, source) VALUES (?,?,?,?,?)",
                (day.isoformat(), metric, value, None, "test"))


def test_recovery_flags_compare_the_week_with_the_four_before_it(con):
    for i in range(120):
        day = START + timedelta(days=i)
        low = i >= 110                                                     # the last ten days dip
        wobble = (i % 5) - 2                                               # ordinary day-to-day noise
        add_metric(con, day, "hrv_ms", (56 if low else 70) + wobble)       # 0.8 of the baseline
        add_metric(con, day, "resting_hr", (56 if low else 50) + wobble * 0.5)
        add_metric(con, day, "sleep_minutes", 330 if low else 480)
    add_set(con, START + timedelta(days=100))                              # trained while fine
    add_set(con, START + timedelta(days=118))                              # trained while down
    ledger.compute(con)
    flags.compute(con)
    found = kinds(con, scope_type="recovery")
    late, early = (START + timedelta(days=118)).isoformat(), (START + timedelta(days=100)).isoformat()
    for kind in ("hrv_suppressed", "rhr_elevated", "short_sleep", "load_on_low_recovery"):
        assert (late, kind) in found
    assert not {k for d, k in found if d <= early}                         # noise alone never fires


def test_a_slow_drift_in_hrv_is_not_a_flag(con):
    for i in range(120):                                                   # falls 15 percent over four months
        add_metric(con, START + timedelta(days=i), "hrv_ms", 80 - i * 0.1)
    flags.compute(con)
    assert not kinds(con, kind="hrv_suppressed")


def test_step_flags(con):
    for i in range(100):
        add_metric(con, START + timedelta(days=i), "steps", 4000 + 200 * (i % 4))
    add_metric(con, START + timedelta(days=100), "steps", 15000)
    for i in range(101, 106):
        add_metric(con, START + timedelta(days=i), "steps", 9000)
    flags.compute(con)
    found = kinds(con, scope_type="steps")
    assert ((START + timedelta(days=100)).isoformat(), "step_day_jump") in found
    assert ((START + timedelta(days=105)).isoformat(), "step_spike") in found
    assert not {d for d, k in found if d < (START + timedelta(days=100)).isoformat()}


def test_replay_applies_steps_to_leg_injuries_only_and_recovery_to_all(con, profile):
    profile.injuries.append({"id": "calf", "label": "Left calf strain", "side": "left",
                             "onset": "2025-03-10", "onset_precision": "day", "tissues": ["calf"]})
    seed_injuries(con, profile)
    onset = date(2025, 3, 10)
    for i in range(1, 120):
        day = onset - timedelta(days=i)
        add_metric(con, day, "steps", 12000 if i <= 5 else 4000)
        add_metric(con, day, "hrv_ms", 50 if i <= 5 else 70)
        if i % 7 == 0:
            add_set(con, day)
    ledger.compute(con)
    flags.compute(con)
    by_label = {r["injury"]: r["kinds"] for r in replay.replay(con, lookback_days=14)}
    calf, pec = by_label["Left calf strain"], by_label["Left pec strain"]
    assert calf["step_spike"]["count"] > 0 and "step_spike" not in pec
    assert calf["hrv_suppressed"]["count"] > 0 and pec["hrv_suppressed"]["count"] > 0
    assert "rhr_elevated" not in pec                                       # never measured
    assert calf["hrv_suppressed"]["windows"] <= calf["spike"]["windows"]


def test_run_query_refuses_everything_but_reading(con, tmp_path):
    from rehabit.mcp_server import Tools
    db_path = con.execute("PRAGMA database_list").fetchone()[2]
    con.commit()
    con.close()
    tools = Tools(db_path)
    assert tools.run_query("select count(*) n from tissue")[0]["n"] > 0
    for sql in ("select * from pragma_database_list",
                "with x as (select 1) insert into tissue values('a','b','c','d')",
                "select 1; attach database 'x.db' as o",
                "select load_extension('x')",
                "with recursive c(x) as (select 1 union all select x+1 from c) select count(*) from c",
                "select zeroblob(1000000000)"):
        assert "error" in tools.run_query(sql), sql
    assert tools.run_query("select zeroblob(8) b")[0]["b"] == "<8 bytes>"
