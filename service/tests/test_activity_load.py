"""Recorded activities as tissue load. Synthetic data only."""

from datetime import date, timedelta

import pytest

from rehabit import db, ledger, library

DAY = date(2026, 3, 2)


def add(con, day, activity_type, minutes, avg_hr=None, max_hr=None, title=None, n=0):
    sid = f"t:{activity_type}:{day}:{n}"
    con.execute(
        "INSERT INTO session(id, start, day, kind, title, activity_type, minutes, avg_hr, max_hr,"
        " source, source_id, imported_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        (sid, f"{day} 08:{n:02d}", day.isoformat(), "cardio", title, activity_type, minutes,
         avg_hr, max_hr, "test", sid, db.now()))


def load(con, tissue, side="left", day=DAY):
    row = con.execute("SELECT dose, sets, reps FROM tissue_load_day WHERE tissue_id = ? AND side = ?"
                      " AND day = ?", (tissue, side, day.isoformat())).fetchone()
    return tuple(row) if row else (0.0, 0, 0)


@pytest.mark.parametrize("type_key,name,expected", [
    ("cycling", "Plainfield Cycling", "cycling"),
    ("indoor_cycling", None, "cycling"),
    ("road_biking", None, "cycling"),
    ("indoor_rowing", "Indoor Rowing", "rowing"),
    ("running", None, "running"),
    ("treadmill_running", None, "running"),
    ("trail_running", None, "running"),
    ("lap_swimming", None, "swimming"),
    ("hiking", None, "hiking"),
    ("stair_climbing", None, "stair_climbing"),
    ("elliptical", None, "elliptical"),
    ("yoga", None, "yoga"),
    ("pilates", None, "pilates"),
    ("pickleball", None, "pickleball"),
    ("indoor_cardio", "Pickleball", "pickleball"),
    ("walking", "Grand Rapids Walking", None),          # its steps are already counted
    ("treadmill_walking", None, None),
    ("strength_training", "Strength", None),            # its sets are the load
    ("indoor_cardio", "Sauna", None),                   # heart rate without load
    ("indoor_cardio", "Cardio", None),                  # a machine nobody named
    ("indoor_cardio", "Rowing", "rowing"),              # named: the name decides
    ("other", None, None),
    ("hand_cycling", None, None),                       # the arms turn it, not the legs
    ("motorcycling", None, None),
    ("wheelchair_push_run", None, None),
    ("backcountry_skiing", None, None),
    ("ice_hockey", None, None),                         # skating, not running steps
    ("e_bike_fitness", None, "cycling"),
    ("virtual_ride", None, "cycling"),
    ("floor_climbing", None, "stair_climbing"),
    ("rucking", None, "hiking"),
    ("hiit", None, "hiit"),
    ("indoor_cardio", "Stationary bike", "cycling"),
    ("indoor_cardio", "Peloton", "cycling"),
    ("indoor_cardio", "Assault bike", "cycling"),
    (None, None, None),
])
def test_activity_types_map_to_a_pattern_or_to_nothing(type_key, name, expected):
    assert library.match_activity(type_key, name) == expected


def test_every_activity_has_a_rate_and_a_pattern():
    for activity, rate in library.ACTIVITIES.items():
        assert rate > 0 and activity in library.EXERCISES
    for _, activity in library._ACTIVITY_PATTERNS:
        assert activity == "" or activity in library.ACTIVITIES


def test_minutes_times_rate_without_heart_rate(con):
    add(con, DAY, "cycling", 40)
    ledger.compute(con)
    dose, sets, reps = load(con, "quads")
    assert dose == pytest.approx(40 * 0.25)           # share 1.0, intensity 1
    assert load(con, "quads", "right")[0] == pytest.approx(10)
    assert load(con, "glute_max")[0] == pytest.approx(5)
    assert (sets, reps) == (0, 0)                     # an activity has no sets to count
    assert load(con, "pec_major") == (0.0, 0, 0)


def test_heart_rate_reserve_scales_linearly_and_is_clamped(con):
    s = ledger.Settings()
    assert ledger.activity_intensity(115, 50, 180, s) == pytest.approx(1.0)    # half the reserve
    assert ledger.activity_intensity(147.5, 50, 180, s) == pytest.approx(1.5)
    assert ledger.activity_intensity(60, 50, 180, s) == 0.5                    # floor
    assert ledger.activity_intensity(200, 50, 180, s) == 2.0                   # ceiling
    assert ledger.activity_intensity(None, 50, 180, s) == 1.0
    assert ledger.activity_intensity(120, None, 180, s) == 1.0
    assert ledger.activity_intensity(120, 50, None, s) == 1.0
    assert ledger.activity_intensity(120, 90, 110, s) == 1.0                   # a range that cannot be right
    assert ledger.activity_intensity(float("nan"), 50, 180, s) == 1.0


def test_intensity_uses_the_usual_resting_rate_and_a_trusted_maximum(con):
    for i in range(29):
        con.execute("INSERT INTO daily_metric(day, metric, value, unit, source) VALUES (?,?,?,?,?)",
                    ((DAY - timedelta(days=i)).isoformat(), "resting_hr", 50, "bpm", "test"))
    # Three earlier recordings and this one: not yet enough to trust 180 as the maximum.
    for i in range(3):
        add(con, DAY - timedelta(days=10 + i), "yoga", 1, avg_hr=70, max_hr=180)
    add(con, DAY, "rowing", 10, avg_hr=147.5, max_hr=150)
    ledger.compute(con)
    assert load(con, "quads")[0] == pytest.approx(10 * 0.65)           # intensity 1 until trusted
    add(con, DAY - timedelta(days=20), "yoga", 1, avg_hr=70, max_hr=170)
    ledger.compute(con)
    assert load(con, "quads")[0] == pytest.approx(10 * 0.65 * 1.5)


def test_unknown_or_counted_activities_add_nothing(con):
    add(con, DAY, "indoor_cardio", 30, avg_hr=140, title="Sauna")
    add(con, DAY, "walking", 60, title="Walk", n=1)
    add(con, DAY, "running", None, n=2)               # no length
    add(con, DAY, "running", -5, n=3)                 # a mistyped length
    ledger.compute(con)
    assert con.execute("SELECT COUNT(*) FROM tissue_load_day").fetchone()[0] == 0


def test_running_adds_to_its_steps_and_the_switch_turns_it_off(con):
    add(con, DAY, "running", 30)
    ledger.compute(con)
    assert load(con, "achilles")[0] == pytest.approx(30 * 2.4)
    assert load(con, "patellar_tendon")[0] == pytest.approx(30 * 2.4 * 0.8)
    assert con.execute("SELECT MAX(walking_dose) FROM tissue_load_day").fetchone()[0] == 0
    ledger.compute(con, ledger.Settings(count_activities=False))
    assert con.execute("SELECT COUNT(*) FROM tissue_load_day").fetchone()[0] == 0


def test_length_is_capped(con):
    add(con, DAY, "cycling", 100000)
    ledger.compute(con)
    assert load(con, "quads")[0] == pytest.approx(600 * 0.25)


def test_the_persons_answer_wins_over_the_type(con):
    add(con, DAY, "indoor_cardio", 20, title="Cardio")
    con.execute("UPDATE session SET counts_as = 'cycling'")
    add(con, DAY, "cycling", 30, title="Ride", n=1)
    con.execute("UPDATE session SET counts_as = 'none' WHERE title = 'Ride'")
    ledger.compute(con)
    assert load(con, "quads")[0] == pytest.approx(20 * 0.25)     # the bike counts, the "none" ride does not


def test_on_foot_activities_count_from_their_steps(con):
    add(con, DAY, "pickleball", 120)
    con.execute("UPDATE session SET steps = 4000")
    ledger.compute(con)
    # 2,000 steps a leg, 100 to a walking rep, three walking steps each less the one already counted.
    assert load(con, "calf")[0] == pytest.approx(2000 / 100 * 2)
    assert load(con, "achilles", "right")[0] == pytest.approx(40)
    assert load(con, "quads")[0] == pytest.approx(20)
    con.execute("UPDATE session SET steps = NULL")
    ledger.compute(con)
    assert load(con, "calf")[0] == pytest.approx(120 * 0.6)          # no steps: minutes x the rate


def test_heart_rate_weight_scales_a_days_walking(con):
    for i in range(3):
        d = (DAY + timedelta(days=i)).isoformat()
        con.execute("INSERT INTO daily_metric(day, metric, value, unit, source) VALUES (?,?,?,?,?)",
                    (d, "steps", 8000, "steps", "test"))
    con.execute("INSERT INTO daily_metric(day, metric, value, unit, source) VALUES (?,?,?,?,?)",
                ((DAY + timedelta(days=1)).isoformat(), "step_hr_weight", 1.5, None, "phone"))
    ledger.compute(con)
    assert load(con, "calf")[0] == pytest.approx(40)
    assert load(con, "calf", day=DAY + timedelta(days=1))[0] == pytest.approx(60)
    ledger.compute(con, ledger.Settings(weight_steps_by_hr=False))
    assert load(con, "calf", day=DAY + timedelta(days=1))[0] == pytest.approx(40)


def test_a_long_court_session_after_a_heavy_day_flags_the_calf(con):
    """Made-up record shaped like the case that asked for these rules: ordinary
    walking, an hour of pickleball a week, then a heavy walking day followed by
    a session twice the usual length."""
    from rehabit import flags
    start = DAY - timedelta(days=120)
    for i in range(121):
        d = start + timedelta(days=i)
        con.execute("INSERT INTO daily_metric(day, metric, value, unit, source) VALUES (?,?,?,?,?)",
                    (d.isoformat(), "steps", 7000 + 900 * (i % 5), "steps", "test"))
        con.execute("INSERT INTO daily_metric(day, metric, value, unit, source) VALUES (?,?,?,?,?)",
                    (d.isoformat(), "resting_hr", 50, "bpm", "test"))
    for week in range(1, 17):
        add(con, DAY - timedelta(days=7 * week + 2), "pickleball", 60, avg_hr=118, max_hr=170)
        con.execute("UPDATE session SET steps = 2200 WHERE day = ?", ((DAY - timedelta(days=7 * week + 2)).isoformat(),))
    con.execute("UPDATE daily_metric SET value = 13000 WHERE metric = 'steps' AND day = ?",
                ((DAY - timedelta(days=1)).isoformat(),))
    con.execute("INSERT INTO daily_metric(day, metric, value, unit, source) VALUES (?,?,?,?,?)",
                ((DAY - timedelta(days=1)).isoformat(), "step_hr_weight", 1.4, None, "phone"))
    add(con, DAY, "pickleball", 115, avg_hr=123, max_hr=175, n=9)
    con.execute("UPDATE session SET steps = 4400 WHERE id LIKE '%:9'")
    ledger.compute(con)
    flags.compute(con)
    found = {(r["kind"], r["scope"]) for r in con.execute(
        "SELECT kind, scope FROM flag WHERE day = ? AND side = 'right'", (DAY.isoformat(),))}
    assert ("activity_jump", "calf") in found and ("activity_jump", "achilles") in found
    assert ("heavy_pair", "calf") in found
    assert not con.execute("SELECT COUNT(*) FROM flag WHERE kind = 'activity_jump' AND day < ?",
                           (DAY.isoformat(),)).fetchone()[0]          # the ordinary weeks stay quiet
