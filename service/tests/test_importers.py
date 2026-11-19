import json
import pytest

from rehabit.importers import doestrack, garmin, hevy
from tests.conftest import garmin_activity


def _sets(con, where="1=1"):
    return [dict(r) for r in con.execute(f"SELECT * FROM set_entry WHERE {where} ORDER BY position")]


def test_hevy_sides_holds_pain_and_conventions(con, profile, hevy_csv):
    counts = hevy.import_csv(con, hevy_csv, profile)
    assert counts["sessions"] == 2 and counts["sets"] == 7 and counts["unmapped"] == 1

    press = _sets(con, "source_exercise = 'Bench Press (Dumbbell)'")
    assert {s["side"] for s in press} == {"left"}          # from the profile rule
    assert all(s["side_inferred"] == 1 for s in press)
    assert press[0]["load_convention"] == "per_hand"
    assert press[0]["pain"] == 3.5
    assert abs(press[0]["load_kg"] - 15 * 0.45359237) < 1e-6

    hold = _sets(con, "exercise_id = 'leg_extension'")[0]
    assert hold["kind"] == "hold" and hold["hold_seconds"] == 20 and hold["reps"] is None
    assert hold["kind_inferred"] == 1 and hold["side"] == "right"

    pushdown = _sets(con, "exercise_id = 'triceps_extension'")[0]
    assert pushdown["side"] == "right"                      # from the note, no rule needed

    squat = _sets(con, "source_exercise = 'Squat (Barbell)'")[0]
    assert squat["side"] == "both" and squat["side_inferred"] == 0   # not a rehab session
    bodyweight = _sets(con, "exercise_id = 'squat_bodyweight'")[0]
    assert bodyweight["load_convention"] == "bodyweight"
    assert abs(bodyweight["load_kg"] - 160 * 0.45359237 * 0.85) < 1e-6


def test_hevy_import_is_idempotent(con, profile, hevy_csv):
    hevy.import_csv(con, hevy_csv, profile)
    hevy.import_csv(con, hevy_csv, profile)
    assert con.execute("SELECT COUNT(*) FROM set_entry").fetchone()[0] == 7
    assert con.execute("SELECT COUNT(*) FROM session").fetchone()[0] == 2


def test_garmin_totals_pullups_and_skips(con, profile, garmin_file):
    path = garmin_file([
        garmin_activity(1, "2025-03-03 16:00", exercises=[
            {"exercise": "bench press", "reps": 20, "sets": 2,
             "avg_weight_per_rep_kg": 11.3, "max_weight_kg": 11.3},
            {"exercise": "pull up", "reps": 10, "sets": 2},
            {"exercise": "pull up", "reps": 12, "sets": 1,
             "avg_weight_per_rep_kg": 54.4, "max_weight_kg": 54.4},
            {"exercise": "pull up", "reps": 5, "sets": 1,
             "avg_weight_per_rep_kg": 9.1, "max_weight_kg": 9.1},
            {"exercise": "unknown", "reps": 8, "sets": 1, "avg_weight_per_rep_kg": 20},
            {"exercise": "unknown", "reps": 0, "sets": 1},
            {"exercise": "lat pulldown", "category": "pull up", "reps": 9, "sets": 1,
             "avg_weight_per_rep_kg": 40, "max_weight_kg": 40},
        ]),
        garmin_activity(2, "2025-03-04 08:00", type_key="breathwork"),
        garmin_activity(3, "2025-03-04 18:00", type_key="running", minutes=20),
        garmin_activity(1, "2025-03-03 16:00", exercises=[]),   # duplicate id, ignored
    ])
    counts = garmin.import_listing(con, [path], profile)
    assert counts == {"sessions": 2, "gym": 1, "cardio": 1, "rows": 6,
                      "unmapped_rows": 1, "skipped": 1}
    rows = _sets(con)
    bw = 160 * 0.45359237
    assert rows[1]["exercise_id"] == "pull_up" and abs(rows[1]["load_kg"] - bw) < 1e-6
    assert rows[2]["exercise_id"] == "pulldown"             # too heavy to be added weight
    assert rows[3]["load_convention"] == "bodyweight_plus"
    assert abs(rows[3]["load_kg"] - (bw + 9.1)) < 1e-6
    assert rows[5]["exercise_id"] == "pulldown"
    run = con.execute("SELECT * FROM session WHERE activity_type = 'running'").fetchone()
    assert run["kind"] == "cardio" and run["minutes"] == 20


def test_garmin_side_is_the_opposite_of_the_rehab_log(con, profile, hevy_csv, garmin_file):
    hevy.import_csv(con, hevy_csv, profile)
    path = garmin_file([garmin_activity(1, "2025-03-03 16:00", exercises=[
        {"exercise": "bench press", "reps": 20, "sets": 2, "avg_weight_per_rep_kg": 11.3},
        {"exercise": "curl", "reps": 20, "sets": 2, "avg_weight_per_rep_kg": 9},
    ])])
    garmin.import_listing(con, [path], profile)
    assert garmin.pair_sides(con) == 1
    rows = {r["source_exercise"]: r for r in _sets(con, "source = 'garmin_bridge'")}
    assert rows["bench press"]["side"] == "right" and rows["bench press"]["side_inferred"] == 1
    assert rows["curl"]["side"] == "both"


def test_doestrack_mirror(con, tmp_path):
    path = tmp_path / "dose.json"
    path.write_text(json.dumps({
        "schemaVersion": 4,
        "medications": [{"id": "m1", "name": "Example", "unit": "MG"}],
        "logs": [
            {"id": "l1", "medicationID": "m1", "takenAt": "2025-03-01T13:00:00Z", "amount": 30,
             "method": "SubQ", "site": "Thigh - Right", "status": "taken"},
            {"id": "l2", "medicationID": "missing", "scheduledAt": "2025-03-02T13:00:00Z"},
            {"id": "l3", "medicationID": "m1"},
        ],
    }))
    assert doestrack.import_backup(con, path)["dose_events"] == 2
    row = con.execute("SELECT * FROM dose_event WHERE id = 'l1'").fetchone()
    assert (row["drug"], row["day"], row["site"]) == ("Example", "2025-03-01", "Thigh - Right")


def test_garmin_daily_keeps_missing_values_missing(con, tmp_path):
    from rehabit.importers import garmin_daily
    nights = tmp_path / "sleep.json"
    nights.write_text(json.dumps({"nights": [
        {"date": "2025-03-01", "hrv": {"last_night_avg_ms": 70}, "total_minutes": 450, "score": 80,
         "avg_heart_rate": 52},
        {"date": "2025-03-02", "total_minutes": 400},                      # no HRV that night
        {"date": None, "no_data": True},
    ]}))
    days = tmp_path / "daily.json"
    days.write_text(json.dumps({"days": [
        {"date": "2025-03-01", "heart_rate": {"resting": 48}, "steps": 6000},
        {"date": "2025-03-02", "heart_rate": {}, "steps": 0},              # watch not worn
    ]}))
    counts = garmin_daily.import_files(con, [nights, days])
    assert counts == {"hrv_ms": 1, "sleep_minutes": 2, "sleep_score": 1, "sleep_hr": 1,
                      "resting_hr": 1, "steps": 1}
    assert garmin_daily.import_files(con, [nights, days]) == counts        # safe to run twice
    assert con.execute("SELECT COUNT(*) FROM daily_metric").fetchone()[0] == 7


def _app_export(tmp_path, **changes):
    """The shape the app writes: times in UTC to the millisecond, days as text."""
    data = {
        "schemaVersion": 1, "exportedAt": "2026-11-17T15:00:00.000Z",
        "profile": {"bodyweightKg": 80.0, "unit": "lb"},
        "workouts": [
            {"id": "W1", "title": "Push", "start": "2026-11-10T22:00:00.000Z",
             "end": "2026-11-10T22:45:00.000Z", "startDay": "2026-11-10", "notes": "",
             "updatedAt": "2026-11-10T22:45:00.000Z"},
            {"id": "hevy:abc", "title": "Rehab", "start": "2026-10-01T21:00:00.000Z",
             "end": "2026-10-01T21:10:00.000Z", "startDay": "2026-10-01", "notes": "",
             "updatedAt": "2026-10-01T21:00:00.000Z"},
            {"id": "OPEN", "title": "Workout", "start": "2026-11-17T14:00:00.000Z",
             "startDay": "2026-11-17", "notes": "", "updatedAt": "2026-11-17T14:00:00.000Z"},
        ],
        "sets": [
            {"id": "S1", "workoutID": "W1", "workoutDay": "2026-11-10", "position": 0,
             "exercise": "Bench Press (Dumbbell)", "pattern": "press_horizontal", "side": "left",
             "kind": "reps", "reps": 10, "loadValue": 15, "loadUnit": "lb", "convention": "per_hand",
             "repsInReserve": 2, "pain": 1.5, "painType": "ache", "isWarmup": False, "notes": "",
             "updatedAt": "2026-11-10T22:10:00.000Z"},
            {"id": "S2", "workoutID": "W1", "workoutDay": "2026-11-10", "position": 1,
             "exercise": "Bench Press (Dumbbell)", "pattern": "press_horizontal", "side": "right",
             "kind": "reps", "reps": 10, "loadValue": 25, "loadUnit": "lb", "convention": "per_hand",
             "isWarmup": True, "notes": "", "updatedAt": "2026-11-10T22:11:00.000Z"},
            {"id": "S3", "workoutID": "W1", "workoutDay": "2026-11-10", "position": 2,
             "exercise": "Push-Up", "pattern": "push_up", "side": "both", "kind": "reps", "reps": 12,
             "loadUnit": "lb", "convention": "bodyweight", "isWarmup": False, "notes": "",
             "updatedAt": "2026-11-10T22:20:00.000Z"},
            {"id": "S4", "workoutID": "W1", "workoutDay": "2026-11-10", "position": 3,
             "exercise": "Wrist Roller", "side": "both", "kind": "hold", "holdSeconds": 30,
             "loadValue": 2, "loadUnit": "kg", "convention": "total", "isWarmup": False,
             "notes": "new toy", "updatedAt": "2026-11-10T22:30:00.000Z"},
            {"id": "hevy:abc:0", "workoutID": "hevy:abc", "workoutDay": "2026-10-01", "position": 0,
             "exercise": "Bench Press (Dumbbell)", "pattern": "press_horizontal", "side": "left",
             "sideInferred": True, "kind": "reps", "reps": 8, "loadValue": 10, "loadUnit": "lb",
             "convention": "per_hand", "isWarmup": False, "notes": "", "updatedAt": "2026-10-01T21:00:00.000Z"},
            {"id": "S9", "workoutID": "OPEN", "workoutDay": "2026-11-17", "position": 0,
             "exercise": "Squat (Barbell)", "pattern": "squat", "side": "both", "kind": "reps",
             "reps": 5, "loadValue": 135, "loadUnit": "lb", "convention": "total",
             "isWarmup": False, "notes": "", "updatedAt": "2026-11-17T14:05:00.000Z"},
        ],
        "injuries": [{"id": "I1", "label": "Left pec", "side": "left", "onset": "2026-06-01",
                      "onsetPrecision": "week", "tissues": ["pec_major"], "mechanism": "",
                      "notes": "", "updatedAt": "2026-06-02T00:00:00.000Z"}],
        "painChecks": [
            {"id": "P1", "injuryID": "I1", "workoutID": "W1", "moment": "after_session",
             "dueAt": "2026-11-10T22:45:00.000Z", "dueDay": "2026-11-10",
             "answeredAt": "2026-11-10T22:50:00.000Z", "pain": 2.0, "painType": "ache",
             "notes": "", "updatedAt": "2026-11-10T22:50:00.000Z"},
            {"id": "P2", "injuryID": "I1", "workoutID": "W1", "moment": "next_morning",
             "dueAt": "2026-11-11T13:00:00.000Z", "dueDay": "2026-11-11", "notes": "",
             "updatedAt": "2026-11-10T22:45:00.000Z"},
        ],
        "dailyMetrics": [{"day": "2026-11-10", "metric": "hrv_ms", "value": 58, "source": "garmin"},
                         {"day": "2026-11-10", "metric": "steps", "value": 9000, "source": "apple_health"}],
        "tombstones": [],
    }
    data.update(changes)
    path = tmp_path / "rehabit-export.json"
    path.write_text(json.dumps(data))
    return path


def test_app_export_keeps_what_was_logged(con, profile, tmp_path):
    from rehabit.importers import app
    counts = app.import_export(con, _app_export(tmp_path), profile)
    assert counts["sessions"] == 2 and counts["sets"] == 5
    assert counts["in_progress"] == 1 and counts["unmapped"] == 1
    assert counts["injuries"] == 1 and counts["pain_checks"] == 2 and counts["daily_metrics"] == 2

    left, right = _sets(con, "source_exercise = 'Bench Press (Dumbbell)' AND session_id = 'app:W1'")
    assert (left["side"], right["side"]) == ("left", "right")
    assert left["side_inferred"] == 0 and left["load_convention"] == "per_hand"
    assert abs(left["load_kg"] - 15 * 0.45359237) < 1e-9 and left["pain"] == 1.5 and left["rpe"] == 8
    assert right["set_type"] == "warmup" and right["rpe"] is None

    # A side the app worked out from an injury is marked, so it is not read as logged.
    assert _sets(con, "session_id = 'app:hevy:abc'")[0]["side_inferred"] == 1

    push_up = _sets(con, "exercise_id = 'push_up'")[0]
    share = __import__("rehabit.library", fromlist=["x"]).EXERCISES["push_up"][1]
    assert abs(push_up["load_kg"] - 80.0 * share) < 1e-9      # the app's body weight, not the profile's

    custom = _sets(con, "source_exercise = 'Wrist Roller'")[0]
    assert custom["exercise_id"] is None and custom["kind"] == "hold" and custom["load_kg"] == 2

    session = dict(con.execute("SELECT * FROM session WHERE id = 'app:W1'").fetchone())
    assert session["day"] == "2026-11-10" and session["minutes"] == 45
    unanswered = dict(con.execute("SELECT * FROM pain_check WHERE id = 'app:P2'").fetchone())
    assert unanswered["pain"] is None and unanswered["answered_at"] is None
    assert con.execute("SELECT tissues FROM injury WHERE id = 'app:I1'").fetchone()[0] == '["pec_major"]'


def test_app_export_is_idempotent_and_drops_what_the_app_dropped(con, profile, tmp_path):
    from rehabit.importers import app
    app.import_export(con, _app_export(tmp_path), profile)
    app.import_export(con, _app_export(tmp_path), profile)
    assert con.execute("SELECT COUNT(*) FROM set_entry").fetchone()[0] == 5
    assert con.execute("SELECT COUNT(*) FROM daily_metric").fetchone()[0] == 2

    app.import_export(con, _app_export(tmp_path, sets=[], painChecks=[], dailyMetrics=[], injuries=[]), profile)
    assert con.execute("SELECT COUNT(*) FROM set_entry").fetchone()[0] == 0
    assert con.execute("SELECT COUNT(*) FROM pain_check").fetchone()[0] == 0
    assert con.execute("SELECT COUNT(*) FROM daily_metric").fetchone()[0] == 0
    assert con.execute("SELECT COUNT(*) FROM injury WHERE id LIKE 'app:%'").fetchone()[0] == 0


def test_app_export_skips_logs_the_service_reads_itself(con, profile, tmp_path, hevy_csv):
    from rehabit.importers import app
    hevy.import_csv(con, hevy_csv, profile)
    counts = app.import_export(con, _app_export(tmp_path), profile, skip_prefixes=("hevy:",))
    assert counts["skipped_sessions"] == 1 and counts["sessions"] == 1 and counts["sets"] == 4
    assert con.execute("SELECT COUNT(*) FROM set_entry WHERE source = 'hevy_csv'").fetchone()[0] == 7


def test_app_export_from_a_newer_app_is_refused(con, profile, tmp_path):
    from rehabit.importers import app
    with pytest.raises(ValueError):
        app.import_export(con, _app_export(tmp_path, schemaVersion=2), profile)


def test_app_sets_reach_the_ledger_and_pain_tool(con, profile, tmp_path):
    from rehabit import ledger
    from rehabit.importers import app
    from rehabit.importers import app
    from rehabit.mcp_server import Tools
    app.import_export(con, _app_export(tmp_path), profile)
    ledger.compute(con)
    rows = con.execute("SELECT side, dose FROM tissue_load_day WHERE tissue_id = 'pec_major'"
                       " AND day = '2026-11-10' ORDER BY side").fetchall()
    assert [r[0] for r in rows] == ["left", "right"] and all(r[1] > 0 for r in rows)
    db_path = con.execute("PRAGMA database_list").fetchone()[2]
    con.close()
    tools = Tools(db_path)
    assert len(tools.get_pain_checks("2026-11-01", "2026-11-30")) == 2
    assert [c["pain"] for c in tools.get_pain_checks("2026-11-01", "2026-11-30", answered_only=True)] == [2.0]


def test_app_export_uses_the_body_weight_of_the_day(con, profile, tmp_path):
    from rehabit import library
    from rehabit.importers import app
    metrics = [{"day": "2026-11-01", "metric": "body_mass_kg", "value": 90, "source": "apple_health"},
               {"day": "2026-11-01", "metric": "body_mass_kg", "value": 88, "source": "manual"},
               {"day": "2026-11-12", "metric": "body_mass_kg", "value": 70, "source": "manual"}]
    app.import_export(con, _app_export(tmp_path, dailyMetrics=metrics), profile)
    push_up = _sets(con, "exercise_id = 'push_up'")[0]
    # Logged on Nov 10: the reading typed in on Nov 1, not the device's and not the later one.
    assert abs(push_up["load_kg"] - 88.0 * library.EXERCISES["push_up"][1]) < 1e-9
    assert app._bodyweight_on(app._bodyweight_by_day({"dailyMetrics": metrics}), "2026-10-01", 80.0) == 88
    assert app._bodyweight_on([], "2026-10-01", 80.0) == 80.0


def test_app_export_carries_effort_tempo_and_the_injury_plan(con, profile, tmp_path):
    import copy
    import sqlite3
    from rehabit import db
    from rehabit.importers import app
    data = json.loads(_app_export(tmp_path).read_text())
    plan = {"rule": {"duringMax": 4, "settleHours": 24}, "milestones": [{"id": "m1", "title": "Bench 135"}],
            "setBy": "", "nextVisit": "2026-12-01"}
    workouts, sets, injuries = (copy.deepcopy(data[k]) for k in ("workouts", "sets", "injuries"))
    workouts = [w for w in workouts if w["id"] == "W1"] + [w for w in workouts if w["id"] != "W1"]
    sets = [s for s in sets if s["workoutID"] == "W1"] + [s for s in sets if s["workoutID"] != "W1"]
    workouts[0]["effort"] = 7.5
    sets[0]["tempo"] = "3-1-1-0"
    sets[1]["tempo"] = 31                      # not text: left out
    injuries[0]["plan"] = plan
    app.import_export(con, _app_export(tmp_path, workouts=workouts, sets=sets, injuries=injuries), profile)
    assert con.execute("SELECT effort FROM session WHERE id = ?", ("app:" + workouts[0]["id"],)).fetchone()[0] == 7.5
    tempo = lambda s: con.execute("SELECT tempo FROM set_entry WHERE id = ?", ("app:" + s["id"],)).fetchone()[0]
    assert tempo(sets[0]) == "3-1-1-0" and tempo(sets[1]) is None
    assert json.loads(con.execute("SELECT plan FROM injury WHERE id = 'app:I1'").fetchone()[0]) == plan
    # An effort outside 0 to 10 is not kept.
    workouts[0]["effort"] = 40
    app.import_export(con, _app_export(tmp_path, workouts=workouts, sets=sets, injuries=injuries), profile)
    assert con.execute("SELECT effort FROM session WHERE id = ?", ("app:" + workouts[0]["id"],)).fetchone()[0] is None

    # A database made before these columns existed gains them when it is opened.
    old = sqlite3.connect(":memory:")
    old.executescript("CREATE TABLE session (id TEXT PRIMARY KEY, start TEXT NOT NULL, end TEXT, day TEXT NOT NULL,"
                      " kind TEXT NOT NULL, title TEXT, activity_type TEXT, minutes REAL, distance_km REAL,"
                      " avg_hr REAL, max_hr REAL, notes TEXT, source TEXT NOT NULL, source_id TEXT NOT NULL,"
                      " imported_at TEXT NOT NULL, UNIQUE (source, source_id));")
    db.init(old)
    assert "effort" in {r[1] for r in old.execute("PRAGMA table_info(session)")}
    assert "tempo" in {r[1] for r in old.execute("PRAGMA table_info(set_entry)")}
    db.init(old)                               # and opening it again changes nothing


def test_app_export_carries_a_recorded_activity_into_the_load(con, profile, tmp_path):
    from rehabit import ledger
    from rehabit.importers import app
    ride = {"id": "garmin:9", "title": "Morning Ride", "start": "2026-11-12T13:00:00.000Z",
            "end": "2026-11-12T13:40:00.000Z", "startDay": "2026-11-12", "notes": "",
            "updatedAt": "2026-11-12T13:40:00.000Z",
            "activity": {"type": "cycling", "distanceMeters": 15000, "averageHeartRate": 120,
                         "maxHeartRate": 150}}
    sauna = {"id": "garmin:10", "title": "Sauna", "start": "2026-11-13T13:00:00.000Z",
             "end": "2026-11-13T13:20:00.000Z", "startDay": "2026-11-13", "notes": "",
             "updatedAt": "2026-11-13T13:20:00.000Z",
             "activity": {"type": "indoor_cardio", "averageHeartRate": "fast"}}
    app.import_export(con, _app_export(tmp_path, workouts=[ride, sauna], sets=[]), profile)
    row = con.execute("SELECT * FROM session WHERE id = 'app:garmin:9'").fetchone()
    assert (row["kind"], row["activity_type"], row["distance_km"], row["avg_hr"], row["max_hr"]) == \
        ("cardio", "cycling", 15.0, 120.0, 150.0)
    assert con.execute("SELECT avg_hr FROM session WHERE id = 'app:garmin:10'").fetchone()[0] is None
    ledger.compute(con)
    quads = con.execute("SELECT dose FROM tissue_load_day WHERE tissue_id = 'quads' AND side = 'left'"
                        " AND day = '2026-11-12'").fetchone()[0]
    assert quads == pytest.approx(40 * 0.25)        # too few heart rates to trust a maximum: intensity 1
    assert con.execute("SELECT COUNT(*) FROM tissue_load_day WHERE day = '2026-11-13' AND dose > 0").fetchone()[0] == 0
