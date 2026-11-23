"""Private data shared by the engine and the independent reference judge."""

import json
from dataclasses import dataclass
from pathlib import Path

Point = tuple[int, int]
Cell = tuple[int, int, int]
State = tuple[Point, ...]


@dataclass(frozen=True)
class Scene:
    public_id: str
    case: str
    variant: str
    seed: int
    logical_size: Point
    viewport: tuple[int, int, int, int]
    active: tuple[int, int, int, int]
    background: int
    letterbox: int
    static: tuple[Cell, ...]
    blocked: tuple[Point, ...]
    holes: tuple[Point, ...]
    bodies: tuple[tuple[Cell, ...], ...]
    start: State
    moves: tuple[tuple[int, int, int], ...]
    path_policy: str
    prefix: tuple[int, ...]

    @property
    def actions(self):
        return tuple(entry[0] for entry in self.moves)

    @classmethod
    def load(cls, path: Path):
        data = json.loads(path.read_bytes())
        for name in ("logical_size", "viewport", "active", "prefix"):
            data[name] = tuple(data[name])
        for name in ("static", "blocked", "holes", "start", "moves"):
            data[name] = tuple(tuple(item) for item in data[name])
        data["bodies"] = tuple(
            tuple(tuple(cell) for cell in cells) for cells in data["bodies"]
        )
        return cls(**data)
