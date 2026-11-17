import pytest

from rehabit import library


@pytest.mark.parametrize("name,expected", [
    ("Bench Press (Dumbbell)", "press_horizontal"),
    ("Incline Bench Press (Barbell)", "press_incline"),
    ("Lying Leg Curls", "leg_curl"),
    ("Bicep Curl (Dumbbell)", "curl"),
    ("Triceps Pull Down", "triceps_extension"),
    ("Lat Pulldown (Cable)", "pulldown"),
    ("pull up", "pull_up"),
    ("Push Up (Weighted)", "push_up"),
    ("Upright Row (Barbell)", "upright_row"),
    ("Seated Cable Row - V Grip (Cable)", "row"),
    ("Romanian Deadlift (Barbell)", "rdl"),
    ("Deadlift (Barbell)", "deadlift"),
    ("Squat (Bodyweight)", "squat_bodyweight"),
    ("Seated Calf Raise", "calf_raise"),
    ("Calf Press on Seated Leg Press", "leg_press"),
    ("dumbbell flye", "fly"),
    ("Hanging Leg Raise", "core"),
    ("Nordic Hamstring Curl", "leg_curl"),
    ("Wrist Curl", "wrist_curl"),
    ("Hip Thrust (Barbell)", "bridge"),
    ("Glute Kickback (Cable)", "bridge"),
    ("Triceps Kickback (Dumbbell)", "triceps_extension"),
    ("Hip Abduction (Machine)", "hip_abduction"),
    ("Hip Adduction (Machine)", "hip_adduction"),
    ("Face Pull", "rear_fly"),
    ("Reverse Fly (Dumbbell)", "rear_fly"),
    ("Chest Dip", "dip"),
    ("External Rotation (Cable)", "shoulder_rotation"),
    ("Lateral Raise (Dumbbell)", "raise_lateral"),
    ("Wall Sit", "squat_bodyweight"),
    ("Russian Twist", "core"),
    ("unknown", None),
    ("Underwater Basket Weaving", None),
])
def test_match_exercise(name, expected):
    assert library.match_exercise(name) == expected


def test_every_link_points_at_a_known_tissue():
    for exercise_id, (_, _, links) in library.EXERCISES.items():
        for tissue_id, (share, role) in links.items():
            assert tissue_id in library.TISSUES, (exercise_id, tissue_id)
            assert 0 < share <= 1
            assert role in {"prime", "assist", "stabiliser", "end_range"}


def test_every_pattern_targets_a_known_exercise():
    for _, exercise_id in library._PATTERNS:
        assert exercise_id in library.EXERCISES


def test_shared_files_are_current():
    """The app loads these. If this fails, run `python3 -m rehabit.cli export-shared`."""
    from rehabit import shared
    for path, text in shared.files().items():
        assert path.read_text() == text, f"{path.name} is stale"


def test_catalogue_points_at_real_patterns():
    from rehabit import library
    assert all(pattern in library.EXERCISES for _, pattern, _, _ in library.CATALOGUE)
    names = [name for name, *_ in library.CATALOGUE]
    assert len(names) == len(set(names))
    assert library.HOLDS <= set(names)
    # A catalogue name maps to its own pattern by the rules too, so a set logged
    # in the app and the same name imported from elsewhere load the same tissues.
    for name, pattern, _, _ in library.CATALOGUE:
        assert library.match_exercise(name) == pattern, name
