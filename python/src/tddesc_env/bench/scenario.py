"""Private data shared by the engine and the independent reference judge."""

import json
from dataclasses import dataclass
from pathlib import Path

Point = tuple[int, int]
Cell = tuple[int, int, int]
Command = int | tuple[int, int, int]


@dataclass(frozen=True)
class State:
    positions: tuple[Point, ...]
    switch_on: bool = False
    resource: int = 0
    selected: int = 0
    flagged: bool = False
    previous_positions: tuple[Point, ...] | None = None


@dataclass(frozen=True)
class Switch:
    panel: Point
    gate_cells: tuple[Point, ...]
    on_color: int
    off_color: int
    initial: bool


@dataclass(frozen=True)
class Resource:
    panel: Point
    gate_cells: tuple[Point, ...]
    color: int
    initial: int


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
    prefix: tuple[Command, ...]
    switch: Switch | None = None
    pushable: bool = False
    resource: Resource | None = None
    selection_color: int | None = None
    initial_selection: int = 0
    dynamics: str = "static"
    signal: Cell | None = None
    goal: Point | None = None
    goal_role: int = 0
    goal_distance: int = 1
    goal_with_signal: bool = False
    tracking_origin: int | None = None
    contact_rule: tuple[int, int] | None = None

    @property
    def start_state(self):
        return State(
            self.start,
            self.switch.initial if self.switch else False,
            self.resource.initial if self.resource else 0,
            self.initial_selection,
        )

    @property
    def actions(self):
        interact = (
            self.switch or self.resource or self.dynamics in ("autonomous", "flash")
        )
        extra = ((5,) if interact else ()) + (
            (6,) if self.selection_color is not None else ()
        )
        if self.dynamics.startswith("undo-"):
            extra += (7,)
        return tuple(entry[0] for entry in self.moves) + extra

    @classmethod
    def load(cls, path: Path):
        data = json.loads(path.read_bytes())
        for name in ("logical_size", "viewport", "active"):
            data[name] = tuple(data[name])
        data["prefix"] = tuple(
            tuple(cmd) if isinstance(cmd, list) else cmd for cmd in data["prefix"]
        )
        for name in ("static", "blocked", "holes", "start", "moves"):
            data[name] = tuple(tuple(item) for item in data[name])
        data["bodies"] = tuple(
            tuple(tuple(cell) for cell in cells) for cells in data["bodies"]
        )
        if data.get("signal") is not None:
            data["signal"] = tuple(data["signal"])
        if data.get("goal") is not None:
            data["goal"] = tuple(data["goal"])
        if data.get("contact_rule") is not None:
            data["contact_rule"] = tuple(data["contact_rule"])
        for name, cls_part in (("switch", Switch), ("resource", Resource)):
            if data.get(name) is not None:
                spec = data[name]
                spec["panel"] = tuple(spec["panel"])
                spec["gate_cells"] = tuple(tuple(cell) for cell in spec["gate_cells"])
                data[name] = cls_part(**spec)
        return cls(**data)
