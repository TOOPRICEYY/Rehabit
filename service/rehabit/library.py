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
    "dip": ("Dip", 1.0, {
        "triceps": (1.0, P), "pec_major": (0.8, P), "front_delt": (0.5, A),
        "rotator_cuff": (0.25, S)}),
    "rear_fly": ("Reverse fly or face pull", 0.0, {
        "rear_delt": (1.0, P), "mid_back": (0.6, A), "rotator_cuff": (0.4, A),
        "upper_traps": (0.3, A)}),
    "shoulder_rotation": ("Shoulder rotation", 0.0, {
        "rotator_cuff": (1.0, P), "rear_delt": (0.3, A)}),
    "shrug": ("Shrug", 0.0, {
        "upper_traps": (1.0, P), "forearm": (0.4, A)}),
    "wrist_curl": ("Wrist curl or grip work", 0.0, {
        "forearm": (1.0, P)}),
    "bridge": ("Glute bridge or hip thrust", 0.0, {
        "glute_max": (1.0, P), "hamstrings": (0.5, A), "glute_med": (0.3, S),
        "erectors": (0.3, S)}),
    "hip_abduction": ("Hip abduction", 0.0, {
        "glute_med": (1.0, P), "glute_max": (0.3, A)}),
    "hip_adduction": ("Hip adduction", 0.0, {
        "adductors": (1.0, P)}),
    # Daily steps, not a logged exercise: it is not in the picker and no
    # exercise name maps to it. Push-off loads the calf and Achilles most; the
    # thigh and hip muscles work at a small fraction of their capacity.
    "walking": ("Walking (daily steps)", 0.0, {
        "calf": (1.0, P), "achilles": (1.0, P), "glute_med": (0.4, S), "quads": (0.3, A),
        "hip_flexors": (0.3, A), "hamstrings": (0.2, A), "glute_max": (0.2, A)}),
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
    ("Side Plank", "core", "bodyweight", True),
    ("Dip", "dip", "bodyweight", False),
    ("Face Pull (Cable)", "rear_fly", "total", False),
    ("Reverse Fly (Dumbbell)", "rear_fly", "per_hand", False),
    ("External Rotation (Cable)", "shoulder_rotation", "per_hand", True),
    ("External Rotation (Band)", "shoulder_rotation", "bodyweight", True),
    ("Shrug (Dumbbell)", "shrug", "per_hand", False),
    ("Wrist Curl (Dumbbell)", "wrist_curl", "per_hand", True),
    ("Nordic Hamstring Curl", "leg_curl", "bodyweight", False),
    ("Seated Calf Raise (Machine)", "calf_raise", "total", False),
    ("Calf Raise (Bodyweight)", "calf_raise", "bodyweight", False),
    ("Single-Leg Calf Raise (Bodyweight)", "calf_raise", "bodyweight", True),
    ("Hip Thrust (Barbell)", "bridge", "total", False),
    ("Glute Bridge", "bridge", "bodyweight", False),
    ("Single-Leg Glute Bridge", "bridge", "bodyweight", True),
    ("Hip Abduction (Machine)", "hip_abduction", "total", False),
    ("Side-Lying Hip Abduction", "hip_abduction", "bodyweight", True),
    ("Clamshell (Band)", "hip_abduction", "bodyweight", True),
    ("Hip Adduction (Machine)", "hip_adduction", "total", False),
    # Staples added after the first round of testing.
    ("Front Squat (Barbell)", "squat", "total", False),
    ("Hack Squat (Machine)", "squat", "total", False),
    ("Smith Machine Squat", "squat", "total", False),
    ("Sumo Deadlift (Barbell)", "deadlift", "total", False),
    ("Good Morning (Barbell)", "rdl", "total", False),
    ("Kettlebell Swing", "rdl", "total", False),
    ("Reverse Lunge (Dumbbell)", "lunge", "per_hand", True),
    ("Walking Lunge (Dumbbell)", "lunge", "per_hand", True),
    ("Split Squat (Bodyweight)", "lunge", "bodyweight", True),
    ("Step-Down (Bodyweight)", "lunge", "bodyweight", True),
    ("Decline Bench Press (Barbell)", "press_horizontal", "total", False),
    ("Close-Grip Bench Press (Barbell)", "press_horizontal", "total", False),
    ("Incline Chest Press (Machine)", "press_incline", "total", False),
    ("Incline Push-Up", "push_up", "bodyweight", False),
    ("Knee Push-Up", "push_up", "bodyweight", False),
    ("Cable Crossover", "fly", "per_hand", False),
    ("Shoulder Press (Machine)", "press_overhead", "total", False),
    ("Arnold Press (Dumbbell)", "press_overhead", "per_hand", False),
    ("Lateral Raise (Machine)", "raise_lateral", "total", False),
    ("Rear Delt Fly (Machine)", "rear_fly", "total", False),
    ("Internal Rotation (Band)", "shoulder_rotation", "bodyweight", True),
    ("T-Bar Row", "row", "total", False),
    ("Seated Row (Machine)", "row", "total", False),
    ("Inverted Row", "row", "bodyweight", False),
    ("Neutral-Grip Pull-Up", "pull_up", "bodyweight", False),
    ("Assisted Pull-Up (Machine)", "pull_up", "bodyweight", False),
    ("Assisted Dip (Machine)", "dip", "bodyweight", False),
    ("Bench Dip", "dip", "bodyweight", False),
    ("Triceps Kickback (Dumbbell)", "triceps_extension", "per_hand", True),
    ("Concentration Curl (Dumbbell)", "curl", "per_hand", True),
    ("Incline Curl (Dumbbell)", "curl", "per_hand", False),
    ("EZ Bar Curl", "curl", "total", False),
    ("Shrug (Barbell)", "shrug", "total", False),
    ("Reverse Wrist Curl (Dumbbell)", "wrist_curl", "per_hand", True),
    ("Seated Leg Curl (Machine)", "leg_curl", "total", False),
    ("Hip Thrust (Machine)", "bridge", "total", False),
    ("Glute Kickback (Cable)", "bridge", "per_hand", True),
    ("Cable Crunch", "core", "total", False),
    ("Ab Wheel Rollout", "core", "bodyweight", False),
    ("Russian Twist", "core", "bodyweight", False),
    ("Leg Raise", "core", "bodyweight", False),
    ("Sit-Up", "core", "bodyweight", False),
    # Isometric holds, logged in seconds (see HOLDS).
    ("Wall Sit", "squat_bodyweight", "bodyweight", False),
    ("Spanish Squat (Band)", "squat_bodyweight", "bodyweight", False),
    ("Isometric Leg Extension (Machine)", "leg_extension", "total", True),
    ("Isometric Leg Curl (Machine)", "leg_curl", "total", True),
    ("Calf Raise Hold", "calf_raise", "bodyweight_plus", True),
    ("Isometric Chest Press (Machine)", "press_horizontal", "total", False),
    ("Isometric Chest Fly (Cable)", "fly", "per_hand", True),
    ("Isometric Biceps Curl (Dumbbell)", "curl", "per_hand", True),
    ("Isometric Triceps Pushdown (Cable)", "triceps_extension", "per_hand", True),
    ("Glute Bridge Hold", "bridge", "bodyweight", False),
    ("Single-Leg Glute Bridge Hold", "bridge", "bodyweight", True),
    ("Copenhagen Plank", "hip_adduction", "bodyweight", True),
    ("Dead Hang", "pull_up", "bodyweight", False),
]

# Catalogue exercises that are held for time instead of counted in reps.
HOLDS: set[str] = {
    "Plank", "Side Plank", "Wall Sit", "Spanish Squat (Band)", "Isometric Leg Extension (Machine)",
    "Isometric Leg Curl (Machine)", "Calf Raise Hold", "Isometric Chest Press (Machine)",
    "Isometric Chest Fly (Cable)", "Isometric Biceps Curl (Dumbbell)",
    "Isometric Triceps Pushdown (Cable)", "Glute Bridge Hold", "Single-Leg Glute Bridge Hold",
    "Copenhagen Plank", "Dead Hang",
}


# First match wins, so the specific patterns come before the general ones.
_PATTERNS: list[tuple[str, str]] = [
    (r"reverse nordic|knee extension|leg extension", "leg_extension"),
    (r"nordic|hamstring curl|leg curl|glute ham", "leg_curl"),
    (r"calf|heel raise", "calf_raise"),
    (r"leg press", "leg_press"),
    (r"side bridge|side plank|hollow|dead bug|pallof", "core"),
    (r"hip thrust|hip raise|bridge|glute kickback|donkey kick|hip extension", "bridge"),
    (r"horizontal abduction", "rear_fly"),
    (r"shoulder abduction", "raise_lateral"),
    (r"abduct|clamshell|side[- ]lying leg|band walk|monster walk|hip (external|internal) rotation", "hip_abduction"),
    (r"adduct|copenhagen", "hip_adduction"),
    (r"\bdips?\b", "dip"),
    (r"skull|tricep|pressdown|push ?down|kickback", "triceps_extension"),
    (r"upright", "upright_row"),
    (r"lat pull ?down|pulldown", "pulldown"),
    (r"pull[- ]?up|chin[- ]?up|dead hang", "pull_up"),
    (r"handstand", "press_overhead"),
    (r"push[- ]?up", "push_up"),
    # "Incline bench" names the bench a curl or a row is done on as often as a press.
    (r"incline(?!.*(curl|\brow|fly|raise)).*press|incline bench(?!.*(curl|\brow|fly|raise))", "press_incline"),
    (r"overhead press|shoulder press|push press|landmine press|arnold|seated dumbbell press|military", "press_overhead"),
    (r"bench(?!.*(curl|\brow|fly|raise))|chest press|dumbbell press|floor press", "press_horizontal"),
    (r"face pull|rear delt|reverse fly|reverse pec deck", "rear_fly"),
    (r"fly|flye|crossover|pec deck", "fly"),
    (r"external rotation|internal rotation|rotator", "shoulder_rotation"),
    (r"shrug", "shrug"),
    (r"leg raise|knee raise", "core"),
    (r"(lateral|front|side|delt|shoulder|\by)[- ]raise", "raise_lateral"),
    (r"wrist", "wrist_curl"),
    (r"curl", "curl"),
    (r"\brow", "row"),
    (r"romanian|rdl|stiff|single[- ]leg deadlift|hyperext|back extension|good morning|swing|pull[- ]?through", "rdl"),
    (r"deadlift", "deadlift"),
    (r"lunge|split squat|step[- ]?(up|down)", "lunge"),
    (r"squat \(bodyweight\)|bodyweight squat|air squat|wall sit|spanish squat", "squat_bodyweight"),
    (r"squat", "squat"),
    (r"sit[- ]?up|crunch|plank|ab wheel|twist|scissor|rotation", "core"),
]


def export() -> dict:
    """The library as plain data, shared with the app so both sides load the same shares."""
    return {
        "tissues": [{"id": i, "name": n, "kind": k, "region": r} for i, (n, k, r) in TISSUES.items()],
        "patterns": [
            {"id": i, "name": n, "bodyweightShare": bw,
             "links": [{"tissue": t, "share": sh, "role": role} for t, (sh, role) in links.items()]}
            for i, (n, bw, links) in EXERCISES.items()],
        "catalogue": [{"name": n, "pattern": p, "convention": c, "unilateral": u,
                       "kind": "hold" if n in HOLDS else "reps"}
                      for n, p, c, u in CATALOGUE],
        # The app maps imported exercise names with the same rules, in this order.
        "matchers": [[pattern, exercise_id] for pattern, exercise_id in _PATTERNS],
    }


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
