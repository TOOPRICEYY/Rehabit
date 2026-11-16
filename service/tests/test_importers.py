import json

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
        garmin_activity(2, "2025-03-04 08:00", type_key="yoga"),
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
