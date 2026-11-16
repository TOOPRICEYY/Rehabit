"""Fixtures are synthetic. No real training or health data belongs in tests."""

import json

import pytest

from rehabit import db, library
from rehabit.profile import Profile


@pytest.fixture
def con(tmp_path):
    con = db.connect(tmp_path / "test.db")
    db.init(con)
    library.seed(con)
    return con


@pytest.fixture
def profile():
    return Profile(
        bodyweight_lb=160,
        rehab_session_titles=["Rehab"],
        rehab_side_rules={"press_horizontal": "left", "leg_extension": "right"},
        injuries=[{
            "id": "pec", "label": "Left pec strain", "side": "left", "onset": "2025-03-10",
            "onset_precision": "day", "tissues": ["pec_major"],
        }],
    )


HEVY_HEADER = ('"title","start_time","end_time","description","exercise_title","superset_id",'
               '"exercise_notes","set_index","set_type","weight_lbs","reps","distance_miles",'
               '"duration_seconds","rpe"\n')


@pytest.fixture
def hevy_csv(tmp_path):
    rows = [
        '"Rehab","3 Mar 2025, 17:00","3 Mar 2025, 17:20","","Bench Press (Dumbbell)",,"3.5/10 pain. Slow",0,"normal",15,10,,,',
        '"Rehab","3 Mar 2025, 17:00","3 Mar 2025, 17:20","","Bench Press (Dumbbell)",,"3.5/10 pain. Slow",1,"normal",15,8,,,',
        '"Rehab","3 Mar 2025, 17:00","3 Mar 2025, 17:20","","Leg Extension (Machine)",,"Iso held 45 deg",0,"normal",10,20,,,',
        '"Rehab","3 Mar 2025, 17:00","3 Mar 2025, 17:20","","Triceps Pushdown",,"Right arm, slow tempo",0,"normal",12.5,10,,,',
        '"Leg Day","1 Feb 2025, 10:00","1 Feb 2025, 11:00","","Squat (Barbell)",,"",0,"normal",135,5,,,',
        '"Leg Day","1 Feb 2025, 10:00","1 Feb 2025, 11:00","","Squat (Bodyweight)",,"",0,"normal",,10,,,',
        '"Leg Day","1 Feb 2025, 10:00","1 Feb 2025, 11:00","","Underwater Basket Weaving",,"",0,"normal",5,5,,,',
    ]
    path = tmp_path / "hevy.csv"
    path.write_text(HEVY_HEADER + "\n".join(rows) + "\n")
    return path


def garmin_activity(activity_id, start, type_key="strength_training", exercises=None, minutes=30):
    act = {"activity_id": activity_id, "start": start, "type_key": type_key,
           "name": type_key, "duration_minutes": minutes}
    if exercises is not None:
        act["strength"] = {"exercises": exercises}
    return act


@pytest.fixture
def garmin_file(tmp_path):
    def write(activities, name="garmin.json"):
        path = tmp_path / name
        path.write_text(json.dumps({"activities": activities}))
        return path
    return write
