"""Round 2 probes of the exercise-name rules. Each test failed because of a defect when it was written.

A name mapped to the wrong pattern is worse than an unmapped one: it puts load on
tissues that did no work and hides the load on those that did. Data is synthetic.
"""

import pytest

from rehabit.importers import hevy
from rehabit.library import match_exercise
from tests.conftest import HEVY_HEADER


@pytest.mark.parametrize("name", ["Rowing Machine", "Rowing", "Indoor Row", "Row Erg"])
def test_a_rowing_machine_is_not_a_strength_row(name):
    assert match_exercise(name) != "row", f"{name!r} (cardio) maps to the strength row pattern"


def test_hevy_rowing_machine_becomes_a_twenty_minute_hold_on_the_lats(con, profile, tmp_path):
    # Hevy's cardio exercise "Rowing Machine" has a duration and no reps.
    path = tmp_path / "hevy.csv"
    path.write_text(HEVY_HEADER + '"Cardio","3 Mar 2025, 07:00","3 Mar 2025, 07:25","","Rowing Machine",,"",0,'
                    '"normal",,,3.1,1200,\n')
    hevy.import_csv(con, path, profile)
    rows = [dict(r) for r in con.execute("SELECT exercise_id, kind, hold_seconds FROM set_entry")]
    assert rows[0]["exercise_id"] is None, (
        f"20 minutes on the rower is stored as {rows[0]}: 240 effective reps on the lats and mid back")


@pytest.mark.parametrize("name", ["Jefferson Curl", "McGill Curl Up", "Curl Up", "Ab Curl"])
def test_a_spine_or_ab_curl_is_not_a_biceps_curl(name):
    assert match_exercise(name) != "curl", f"{name!r} maps to the biceps curl"


@pytest.mark.parametrize("name", ["Bench Step Up", "Bench Split Squat", "Decline Bench Sit Up",
                                  "Bench Hyperextension"])
def test_a_bench_used_as_equipment_is_not_a_bench_press(name):
    assert match_exercise(name) != "press_horizontal", f"{name!r} maps to the bench press"


@pytest.mark.parametrize("name", ["Calf Stretch", "Leg Swings", "Neck Rotation", "Thoracic Rotation"])
def test_a_stretch_or_mobility_drill_is_not_a_loaded_exercise(name):
    assert match_exercise(name) is None, f"{name!r} maps to {match_exercise(name)!r}"


def test_a_straight_leg_raise_is_not_an_ab_exercise():
    # The rehab straight leg raise works the quadriceps and hip flexors lying down;
    # the "core" pattern puts it on the abdominals and gives the quadriceps nothing.
    assert match_exercise("Straight Leg Raise") != "core"
