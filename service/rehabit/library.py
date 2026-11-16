"""Tissues, canonical exercises and the exercise-to-tissue map.

Shares are starting estimates, not measurements: 1.0 for a prime mover, about 0.5
for an assisting muscle, 0.25 for a stabiliser, and a small "end_range" share for a
tissue that is stretched under load at the end of the movement. They are stored
with estimate_source='default' so later corrections can be told apart.
"""

from __future__ import annotations

import re
import sqlite3

# id: (display name, kind, region)
TISSUES: dict[str, tuple[str, str, str]] = {
    "pec_major": ("Pectoralis major", "muscle", "chest"),
    "front_delt": ("Front deltoid", "muscle", "shoulder"),
    "side_delt": ("Side deltoid", "muscle", "shoulder"),
    "rear_delt": ("Rear deltoid", "muscle", "shoulder"),
    "rotator_cuff": ("Rotator cuff", "muscle", "shoulder"),
    "triceps": ("Triceps", "muscle", "upper arm"),
    "biceps": ("Biceps and brachialis", "muscle", "upper arm"),
    "forearm": ("Forearm flexors and grip", "muscle", "forearm"),
    "lats": ("Latissimus dorsi", "muscle", "back"),
    "mid_back": ("Rhomboids and mid trapezius", "muscle", "back"),
    "upper_traps": ("Upper trapezius", "muscle", "back"),
    "erectors": ("Spinal erectors", "muscle", "back"),
    "abs": ("Abdominals", "muscle", "trunk"),
    "obliques": ("Obliques", "muscle", "trunk"),
    "hip_flexors": ("Hip flexors", "muscle", "hip"),
    "glute_max": ("Gluteus maximus", "muscle", "hip"),
    "glute_med": ("Gluteus medius", "muscle", "hip"),
    "adductors": ("Adductors", "muscle", "thigh"),
    "quads": ("Quadriceps", "muscle", "thigh"),
    "hamstrings": ("Hamstrings", "muscle", "thigh"),
    "patellar_tendon": ("Patellar tendon", "tendon", "knee"),
    "calf": ("Gastrocnemius and soleus", "muscle", "lower leg"),
    "achilles": ("Achilles tendon", "tendon", "lower leg"),
}

P, A, S, E = "prime", "assist", "stabiliser", "end_range"

# id: (display name, bodyweight share, {tissue: (share, role)})
EXERCISES: dict[str, tuple[str, float, dict[str, tuple[float, str]]]] = {
    "press_horizontal": ("Horizontal press", 0.0, {
        "pec_major": (1.0, P), "front_delt": (0.5, A), "triceps": (0.5, A),
        "rotator_cuff": (0.25, S)}),
    "press_incline": ("Incline press", 0.0, {
        "pec_major": (0.8, P), "front_delt": (0.7, A), "triceps": (0.5, A),
        "rotator_cuff": (0.25, S)}),
    "push_up": ("Push-up", 0.64, {
        "pec_major": (1.0, P), "front_delt": (0.5, A), "triceps": (0.5, A),
        "abs": (0.25, S)}),
    "fly": ("Chest fly", 0.0, {
        "pec_major": (1.0, P), "front_delt": (0.4, A), "biceps": (0.15, S)}),
    "press_overhead": ("Overhead press", 0.0, {
        "front_delt": (1.0, P), "side_delt": (0.5, A), "triceps": (0.6, A),
        "upper_traps": (0.4, A), "rotator_cuff": (0.3, S), "pec_major": (0.2, A)}),
    "raise_lateral": ("Lateral or front raise", 0.0, {
        "side_delt": (1.0, P), "front_delt": (0.4, A), "upper_traps": (0.4, A),
        "rotator_cuff": (0.3, S)}),
    "upright_row": ("Upright row", 0.0, {
        "side_delt": (0.8, P), "upper_traps": (0.8, P), "biceps": (0.4, A),
        "rotator_cuff": (0.3, S)}),
    "triceps_extension": ("Triceps extension or pushdown", 0.0, {
        "triceps": (1.0, P), "forearm": (0.2, S)}),
    "curl": ("Biceps curl", 0.0, {
        "biceps": (1.0, P), "forearm": (0.5, A), "front_delt": (0.15, S)}),
    # The pec share on rows and pull-ups is small but deliberate: it is loaded while
    # stretched at full retraction or at the bottom of the hang.
    "row": ("Row", 0.0, {
        "lats": (0.8, P), "mid_back": (1.0, P), "rear_delt": (0.5, A),
        "biceps": (0.5, A), "forearm": (0.4, A), "erectors": (0.25, S),
        "pec_major": (0.1, E)}),
    "pull_up": ("Pull-up or chin-up", 1.0, {
        "lats": (1.0, P), "biceps": (0.7, A), "mid_back": (0.5, A),
        "forearm": (0.5, A), "rear_delt": (0.3, A), "pec_major": (0.25, A),
        "abs": (0.2, S)}),
    "pulldown": ("Lat pulldown", 0.0, {
        "lats": (1.0, P), "biceps": (0.6, A), "mid_back": (0.5, A),
        "forearm": (0.4, A), "rear_delt": (0.3, A), "pec_major": (0.2, A)}),
    "deadlift": ("Deadlift", 0.0, {
        "glute_max": (1.0, P), "hamstrings": (0.8, P), "erectors": (0.8, P),
        "quads": (0.4, A), "lats": (0.3, S), "forearm": (0.5, A),
        "upper_traps": (0.4, S), "adductors": (0.3, A)}),
    "rdl": ("Romanian deadlift or back extension", 0.0, {
        "hamstrings": (1.0, P), "glute_max": (0.8, P), "erectors": (0.7, P),
        "forearm": (0.4, A)}),
    "squat": ("Squat", 0.0, {
        "quads": (1.0, P), "glute_max": (0.8, P), "adductors": (0.5, A),
        "erectors": (0.4, S), "patellar_tendon": (0.6, A), "calf": (0.15, S)}),
    "squat_bodyweight": ("Bodyweight squat", 0.85, {
        "quads": (1.0, P), "glute_max": (0.8, P), "adductors": (0.5, A),
        "patellar_tendon": (0.6, A)}),
    "lunge": ("Lunge", 0.0, {
        "quads": (1.0, P), "glute_max": (0.9, P), "glute_med": (0.4, S),
        "adductors": (0.4, A), "patellar_tendon": (0.6, A), "calf": (0.2, S)}),
    "leg_press": ("Leg press", 0.0, {
        "quads": (1.0, P), "glute_max": (0.6, A), "adductors": (0.3, A),
        "patellar_tendon": (0.6, A)}),
    "leg_extension": ("Leg extension", 0.0, {
        "quads": (1.0, P), "patellar_tendon": (0.8, A)}),
    "leg_curl": ("Leg curl", 0.0, {
        "hamstrings": (1.0, P), "calf": (0.2, A)}),
    "calf_raise": ("Calf raise", 0.0, {
        "calf": (1.0, P), "achilles": (1.0, P)}),
    "core": ("Trunk exercise", 0.0, {
        "abs": (1.0, P), "obliques": (0.5, A), "hip_flexors": (0.5, A)}),
}

# Named exercises offered by the app's picker: (name, movement pattern, how the
# load is entered, whether it is usually done one side at a time). The pattern
# decides which tissues are loaded; a custom exercise picks a pattern the same way.
CATALOGUE: list[tuple[str, str, str, bool]] = [
    ("Bench Press (Barbell)", "press_horizontal", "total", False),
    ("Bench Press (Dumbbell)", "press_horizontal", "per_hand", False),
    ("Single-Arm Bench Press (Dumbbell)", "press_horizontal", "per_hand", True),
    ("Chest Press (Machine)", "press_horizontal", "total", False),
    ("Floor Press (Dumbbell)", "press_horizontal", "per_hand", False),
    ("Incline Bench Press (Barbell)", "press_incline", "total", False),
    ("Incline Bench Press (Dumbbell)", "press_incline", "per_hand", False),
    ("Push-Up", "push_up", "bodyweight", False),
    ("Chest Fly (Dumbbell)", "fly", "per_hand", False),
    ("Chest Fly (Cable)", "fly", "per_hand", True),
    ("Pec Deck (Machine)", "fly", "total", False),
    ("Overhead Press (Barbell)", "press_overhead", "total", False),
    ("Shoulder Press (Dumbbell)", "press_overhead", "per_hand", False),
    ("Lateral Raise (Dumbbell)", "raise_lateral", "per_hand", False),
    ("Lateral Raise (Cable)", "raise_lateral", "per_hand", True),
    ("Front Raise (Dumbbell)", "raise_lateral", "per_hand", False),
    ("Upright Row (Cable)", "upright_row", "total", False),
    ("Triceps Pushdown (Cable)", "triceps_extension", "total", False),
    ("Single-Arm Triceps Pushdown (Cable)", "triceps_extension", "per_hand", True),
    ("Overhead Triceps Extension (Dumbbell)", "triceps_extension", "per_hand", True),
    ("Skullcrusher (EZ Bar)", "triceps_extension", "total", False),
    ("Biceps Curl (Dumbbell)", "curl", "per_hand", False),
    ("Biceps Curl (Barbell)", "curl", "total", False),
    ("Biceps Curl (Cable)", "curl", "per_hand", True),
    ("Hammer Curl (Dumbbell)", "curl", "per_hand", False),
    ("Preacher Curl (Machine)", "curl", "total", False),
    ("Bent Over Row (Barbell)", "row", "total", False),
    ("Single-Arm Row (Dumbbell)", "row", "per_hand", True),
    ("Seated Row (Cable)", "row", "total", False),
    ("Chest Supported Row (Machine)", "row", "total", False),
    ("Pull-Up", "pull_up", "bodyweight", False),
    ("Chin-Up", "pull_up", "bodyweight", False),
    ("Weighted Pull-Up", "pull_up", "bodyweight_plus", False),
    ("Lat Pulldown (Cable)", "pulldown", "total", False),
    ("Single-Arm Lat Pulldown (Cable)", "pulldown", "per_hand", True),
    ("Deadlift (Barbell)", "deadlift", "total", False),
    ("Trap Bar Deadlift", "deadlift", "total", False),
    ("Romanian Deadlift (Barbell)", "rdl", "total", False),
    ("Romanian Deadlift (Dumbbell)", "rdl", "per_hand", False),
    ("Single-Leg Romanian Deadlift (Dumbbell)", "rdl", "per_hand", True),
    ("Back Extension", "rdl", "bodyweight_plus", False),
    ("Squat (Barbell)", "squat", "total", False),
    ("Goblet Squat (Dumbbell)", "squat", "total", False),
    ("Squat (Bodyweight)", "squat_bodyweight", "bodyweight", False),
    ("Lunge (Dumbbell)", "lunge", "per_hand", True),
    ("Bulgarian Split Squat (Dumbbell)", "lunge", "per_hand", True),
    ("Step-Up (Dumbbell)", "lunge", "per_hand", True),
    ("Leg Press (Machine)", "leg_press", "total", False),
    ("Single-Leg Press (Machine)", "leg_press", "total", True),
    ("Leg Extension (Machine)", "leg_extension", "total", False),
    ("Single-Leg Extension (Machine)", "leg_extension", "total", True),
    ("Leg Curl (Machine)", "leg_curl", "total", False),
    ("Single-Leg Curl (Machine)", "leg_curl", "total", True),
    ("Calf Raise (Machine)", "calf_raise", "total", False),
    ("Single-Leg Calf Raise (Dumbbell)", "calf_raise", "per_hand", True),
    ("Plank", "core", "bodyweight", False),
    ("Crunch", "core", "bodyweight", False),
    ("Hanging Leg Raise", "core", "bodyweight", False),
]


def export() -> dict:
    """The library as plain data, shared with the app so both sides load the same shares."""
    return {
        "tissues": [{"id": i, "name": n, "kind": k, "region": r} for i, (n, k, r) in TISSUES.items()],
        "patterns": [
            {"id": i, "name": n, "bodyweightShare": bw,
             "links": [{"tissue": t, "share": sh, "role": role} for t, (sh, role) in links.items()]}
            for i, (n, bw, links) in EXERCISES.items()],
        "catalogue": [{"name": n, "pattern": p, "convention": c, "unilateral": u}
                      for n, p, c, u in CATALOGUE],
    }


# First match wins, so the specific patterns come before the general ones.
_PATTERNS: list[tuple[str, str]] = [
    (r"leg curl", "leg_curl"),
    (r"leg extension", "leg_extension"),
    (r"leg press|calf press", "leg_press"),
    (r"calf", "calf_raise"),
    (r"skull|tricep|pressdown|push ?down|kickback", "triceps_extension"),
    (r"upright", "upright_row"),
    (r"lat pull ?down|pulldown", "pulldown"),
    (r"pull[- ]?up|chin[- ]?up", "pull_up"),
    (r"push[- ]?up", "push_up"),
    (r"incline.*press|incline bench", "press_incline"),
    (r"overhead press|shoulder press|arnold|seated dumbbell press|military", "press_overhead"),
    (r"bench|chest press|dumbbell press|floor press", "press_horizontal"),
    (r"fly|flye|crossover|pec deck", "fly"),
    (r"lateral raise|front raise|raise", "raise_lateral"),
    (r"curl", "curl"),
    (r"row", "row"),
    (r"romanian|rdl|hyperext|back extension|good morning", "rdl"),
    (r"deadlift", "deadlift"),
    (r"squat \(bodyweight\)|bodyweight squat|air squat", "squat_bodyweight"),
    (r"squat", "squat"),
    (r"lunge|split squat|step[- ]?up", "lunge"),
    (r"sit[- ]?up|crunch|plank|ab wheel|twist|scissor|rotation|leg raise", "core"),
]
_COMPILED = [(re.compile(p), ex) for p, ex in _PATTERNS]


def match_exercise(source_name: str) -> str | None:
    """Map a source's exercise name to a canonical exercise id, or None."""
    name = source_name.strip().lower()
    if not name or name == "unknown":
        return None
    for pattern, exercise_id in _COMPILED:
        if pattern.search(name):
            return exercise_id
    return None


def seed(con: sqlite3.Connection) -> None:
    """Write the default library. Rows edited later (non-default source) are kept."""
    for tissue_id, (name, kind, region) in TISSUES.items():
        con.execute(
            "INSERT OR REPLACE INTO tissue(id, name, kind, region) VALUES (?,?,?,?)",
            (tissue_id, name, kind, region),
        )
    for exercise_id, (name, bw_share, links) in EXERCISES.items():
        con.execute(
            "INSERT OR REPLACE INTO exercise(id, name, bodyweight_share) VALUES (?,?,?)",
            (exercise_id, name, bw_share),
        )
        for tissue_id, (share, role) in links.items():
            con.execute(
                "INSERT OR IGNORE INTO exercise_tissue"
                "(exercise_id, tissue_id, share, role) VALUES (?,?,?,?)",
                (exercise_id, tissue_id, share, role),
            )
    con.commit()
