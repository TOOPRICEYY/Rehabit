"""Personal settings that must not live in code: body weight, which sessions are
rehab sessions, which side each rehab exercise is on, and known injuries.

The real file is data/profile.json, which is ignored by git. See
profile.example.json for the shape.
"""

from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Profile:
    bodyweight_lb: float = 160.0
    # Titles of sessions in the old log that tracked only the rehabbing side.
    rehab_session_titles: list[str] = field(default_factory=list)
    # exercise id -> "left" | "right": the side a rehab-session exercise was done on.
    rehab_side_rules: dict[str, str] = field(default_factory=dict)
    injuries: list[dict] = field(default_factory=list)

    @property
    def bodyweight_kg(self) -> float:
        return self.bodyweight_lb * LB_TO_KG


LB_TO_KG = 0.45359237


def load(path: str | Path | None) -> Profile:
    if path is None or not Path(path).exists():
        return Profile()
    raw = json.loads(Path(path).read_text())
    return Profile(
        bodyweight_lb=float(raw.get("bodyweight_lb", 160.0)),
        rehab_session_titles=list(raw.get("rehab_session_titles", [])),
        rehab_side_rules=dict(raw.get("rehab_side_rules", {})),
        injuries=list(raw.get("injuries", [])),
    )


def seed_injuries(con: sqlite3.Connection, profile: Profile) -> int:
    for inj in profile.injuries:
        con.execute(
            "INSERT OR REPLACE INTO injury(id, label, side, onset, onset_precision,"
            " onset_recalled, mechanism, stage, tissues, activity_types, notes)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (
                inj["id"], inj["label"], inj["side"], inj["onset"],
                inj.get("onset_precision", "day"), int(inj.get("onset_recalled", True)),
                inj.get("mechanism"), inj.get("stage"),
                json.dumps(inj.get("tissues", [])),
                json.dumps(inj.get("activity_types", [])), inj.get("notes"),
            ),
        )
    con.commit()
    return len(profile.injuries)
