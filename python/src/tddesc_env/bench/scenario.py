"""Private data shared by the engine and the independent reference judge."""

import json
from dataclasses import dataclass
from pathlib import Path

Point = tuple[int, int]
Cell = tuple[int, int, int]


@dataclass(frozen=True)
class State:
    positions: tuple[Point, ...]
    switch_on: bool = False


@dataclass(frozen=True)
class Switch:
    panel: Point
    gate_cells: tuple[Point, ...]
    on_color: int
    off_color: int
    initial: bool


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
    start: tuple[Point, ...]
    moves: tuple[tuple[int, int, int], ...]
    path_policy: str
    prefix: tuple[int, ...]
    switch: Switch | None = None

    @property
    def start_state(self):
        return State(self.start, self.switch.initial if self.switch else False)

    @property
    def actions(self):
        return tuple(entry[0] for entry in self.moves) + ((5,) if self.switch else ())

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
        if data.get("switch") is not None:
            spec = data["switch"]
            spec["panel"] = tuple(spec["panel"])
            spec["gate_cells"] = tuple(tuple(cell) for cell in spec["gate_cells"])
            data["switch"] = Switch(**spec)
        return cls(**data)
