"""Generate paired, deterministic private fixtures with opaque public IDs."""

import argparse
import json
import random
import tomllib
from dataclasses import asdict, replace
from hashlib import sha256
from pathlib import Path

from .scenario import Resource, Scene, Switch

CASES = tuple(f"M{index:02}" for index in range(1, 15))
DIRECTIONS = ((1, 1, 0), (2, -1, 0), (3, 0, -1), (4, 0, 1))


def read_plan(path):
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    fields = {
        "schema_version",
        "generator_version",
        "logical_size",
        "training_seeds",
        "development_seeds",
        "evaluation_seeds",
        "cases",
    }
    if data.keys() != fields or any(
        type(data[key]) is not int or data[key] != 1
        for key in ("schema_version", "generator_version")
    ):
        raise ValueError("Unsupported scenario configuration")
    if data["logical_size"] != [24, 20] or tuple(data["cases"]) != CASES:
        raise ValueError("Unsupported fixture slice")
    groups = [
        data[k] for k in ("training_seeds", "development_seeds", "evaluation_seeds")
    ]
    if not all(isinstance(seeds, list) and seeds for seeds in groups):
        raise ValueError("Empty seed group")
    seeds = [seed for group in groups for seed in group]
    if not all(type(seed) is int and seed >= 0 for seed in seeds) or len(seeds) != len(
        set(seeds)
    ):
        raise ValueError("Invalid or overlapping seed groups")
    return data


def scenes(plan, seed):
    if not any(
        seed in plan[key]
        for key in ("training_seeds", "development_seeds", "evaluation_seeds")
    ):
        raise ValueError("Seed outside the declared split")
    colors = list(range(16))
    random.Random(seed).shuffle(colors)
    bg, box, body, wall, detail = colors[:5]
    square = tuple((x, y, body) for y in range(2) for x in range(2))
    wide = tuple((x, y, body) for y in range(2) for x in range(3))
    width, height = plan["logical_size"]
    shift = 0 if seed == plan["training_seeds"][0] else 1

    def item(case, variant, **changes):
        identity = sha256(f"fixture-v1/{seed}/{case}/{variant}".encode()).hexdigest()
        base = Scene(
            f"b{identity[:3]}-{identity[3:11]}",
            case,
            variant,
            seed,
            (width, height),
            (0, 0, width, height),
            (1, 3, 14, 13),
            bg,
            box,
            (),
            (),
            (),
            (square,),
            ((3 + shift, 6),),
            DIRECTIONS,
            "endpoint",
            (1,),
        )
        return replace(base, **changes)

    top = (5 + shift, 6)
    edge = (5 + shift, 7)
    peer = (10, 8)
    rectangular_cards = [(x + peer[0], y + peer[1], color) for x, y, color in square]
    parts = [
        item("M01", "open-wide", bodies=(wide,)),
        item("M01", "open-square", start=((4 + shift, 8),)),
        item(
            "M01",
            "edge-blocker",
            bodies=(wide,),
            static=((6 + shift, 7, wall),),
            blocked=((6 + shift, 7),),
        ),
        item(
            "M01",
            "same-color-distractor",
            bodies=(wide,),
            static=tuple(rectangular_cards),
        ),
        item(
            "M01",
            "equal-appearance-swap",
            bodies=(square, square),
            start=((3 + shift, 6), peer),
            moves=((1, 0, 0),),
            path_policy="swap",
        ),
        item(
            "M01",
            "equal-appearance-idle",
            bodies=(square, square),
            start=((3 + shift, 6), peer),
            moves=((1, 0, 0),),
        ),
        item("M02", "wide-corridor", active=(2, 6, 12, 8)),
        item(
            "M02",
            "narrow-corridor",
            active=(2, 6, 12, 8),
            static=((*edge, wall),),
            blocked=(edge,),
        ),
        item("M02", "floor-hole", holes=(edge,), static=((*edge, wall),)),
        item("M02", "active-boundary", active=(2, 6, 5 + shift, 8)),
        item(
            "M02",
            "l-notch",
            bodies=(((0, 0, body), (1, 0, body), (0, 1, body)),),
            static=((*edge, wall),),
            blocked=(edge,),
        ),
        item(
            "M02",
            "long-endpoint",
            moves=((1, 3, 0), (2, -3, 0)),
            static=((*top, wall),),
            blocked=(top,),
        ),
        item(
            "M02",
            "long-swept",
            moves=((1, 3, 0), (2, -3, 0)),
            static=((*top, wall),),
            blocked=(top,),
            path_policy="swept",
        ),
        item("M02", "offscreen-open", viewport=(0, 0, 5 + shift, 20)),
        item(
            "M02",
            "offscreen-blocked",
            viewport=(0, 0, 5 + shift, 20),
            static=((*edge, wall),),
            blocked=(edge,),
        ),
        item(
            "M13",
            "bridge-and-diagonal",
            bodies=(),
            start=(),
            moves=((1, 0, 0),),
            static=tuple(
                (x + shift, y, body)
                for x, y in [
                    (2, 6),
                    (3, 6),
                    (2, 7),
                    (3, 7),
                    (4, 6),
                    (5, 6),
                    (6, 6),
                    (5, 7),
                    (6, 7),
                ]
            )
            + ((14, 12, detail), (15, 13, detail)),
        ),
        item(
            "M13",
            "multicolor-rigid",
            bodies=(((0, 0, body), (1, 0, detail), (0, 1, body)),),
        ),
        item(
            "M13",
            "touch-and-separate",
            bodies=(square, square),
            start=((3 + shift, 6), (6 + shift, 6)),
            prefix=(1, 2),
        ),
    ]
    gate_x, gate_y = 9 + shift, 6
    panel = Switch(
        (18, 1), ((gate_x, gate_y), (gate_x, gate_y + 1)), detail, wall, True
    )
    divider = tuple(
        (gate_x, y, wall) for y in range(3, 13) if y not in (gate_y, gate_y + 1)
    )
    common = {
        "start": ((gate_x - 2, gate_y),),
        "moves": ((1, 1, 0),),
        "blocked": tuple((x, y) for x, y, _ in divider),
    }
    for variant, initial, noise, crop, prefix, y in (
        ("panel-open", True, box, False, (1,), gate_y),
        ("panel-closed", False, box, False, (1,), gate_y),
        ("panel-toggle", False, box, False, (1, 5, 1), gate_y),
        ("panel-unrelated", True, wall, False, (1,), gate_y),
        ("panel-cropped-open", True, box, True, (1,), gate_y),
        ("panel-cropped-closed", False, box, True, (1,), gate_y),
        ("panel-position-heldout", True, box, False, (1,), gate_y),
    ):
        updates = dict(common)
        wall_shape = divider
        switch = replace(panel, initial=initial)
        if variant == "panel-position-heldout":
            pixel = gate_x + 1
            wall_shape = tuple((pixel, py, color) for _, py, color in divider)
            switch = replace(switch, gate_cells=((pixel, y), (pixel, y + 1)))
            updates["start"] = ((pixel - 2, y),)
            updates["blocked"] = tuple((x, yy) for x, yy, _ in wall_shape)
        parts.append(
            item(
                "M05",
                variant,
                **updates,
                switch=switch,
                prefix=prefix,
                static=(*wall_shape, (16, 2, noise)),
                viewport=(0, 4, width, 12) if crop else (0, 0, width, height),
            )
        )
    push_start = ((3 + shift, 6), (5 + shift, 6))
    obstacle = ((0, 0, wall), (0, 1, wall))
    behind = (6 + shift, 7)
    for variant, pushable, blocked in (
        ("push-open", True, False),
        ("push-blocked", True, True),
        ("push-immovable", False, False),
    ):
        parts.append(
            item(
                "M04",
                variant,
                bodies=(square, obstacle),
                start=push_start,
                pushable=pushable,
                moves=((1, 1, 0), (2, -1, 0)),
                active=(2, 6, 12, 8),
                blocked=(behind,) if blocked else (),
                static=((*behind, detail),) if blocked else (),
            )
        )
    for variant, amount, is_hidden, prefix in (
        ("resource-one", 1, False, (1, 1)),
        ("resource-zero", 0, False, (1,)),
        ("resource-two", 2, False, (1,)),
        ("resource-no-movement", 1, False, (5, 1)),
        ("resource-hidden", 1, True, (1,)),
    ):
        parts.append(
            item(
                "M06",
                variant,
                **common,
                static=divider,
                prefix=prefix,
                resource=Resource((18, 1), panel.gate_cells, detail, amount),
                viewport=(0, 4, width, 12) if is_hidden else (0, 0, width, height),
            )
        )

    for variant, camera, difference, selection in (
        ("click-interior", (0, 0, width, height), "inside", 0),
        ("click-edge-outside", (0, 0, width, height), "edge", 0),
        ("click-letterbox", (0, 0, width, height), "blank", 0),
        ("click-panel", (0, 0, width, height), "panel", 0),
        ("click-between", (0, 0, width, height), "between", 0),
        ("click-viewport21", (1, 1, 21, 17), "inside", 0),
        ("click-overlap-a", (0, 0, width, height), "overlap", 0),
        ("click-overlap-b", (0, 0, width, height), "overlap", 1),
    ):
        a, b = (5 + shift, 6), (11 + shift, 6)
        left, top, cols, rows = camera
        scale = 64 // max(cols, rows)

        def screen(point):
            x, y = point
            return (
                (64 - cols * scale) // 2 + (x - left) * scale,
                (64 - rows * scale) // 2 + (y - top) * scale,
            )

        points = {
            "inside": screen(b),
            "edge": (screen(b)[0] - 1, screen(b)[1]),
            "blank": (0, 0),
            "panel": screen((17, 2)),
            "between": screen((8 + shift, 6)),
            "overlap": screen(a),
        }
        parts.append(
            item(
                "M08",
                variant,
                viewport=camera,
                active=(3, 6, 16, 8),
                start=(a, a if difference == "overlap" else b),
                bodies=(square, square),
                selection_color=detail,
                initial_selection=selection,
                static=((17, 2, wall),),
                moves=((1, 1, 0), (2, -1, 0)),
                prefix=((6, *points[difference]), 1),
            )
        )
    # The mask marks geometry. A same-colored display occupies a separate part
    # of the viewport without becoming a traversable cell.
    left = {(x, y) for x in range(2, 5 + shift) for y in range(5, 9)}
    right = {(x, y) for x in range(9 + shift, 13 + shift) for y in range(5, 9)}
    island = {(x, y) for x in range(16, 19) for y in range(5, 9)}
    panel_pixels = {(x, y) for x in range(16, 19) for y in range(2, 4)}
    for name, bridge_y in (("walk-narrow-bridge", (6,)), ("walk-wide-bridge", (6, 7))):
        bridge = {(x, y) for x in range(5 + shift, 9 + shift) for y in bridge_y}
        floor = left | bridge | right | island
        holes = {(x, y) for x in range(1, 22) for y in range(1, 16)} - floor
        parts.append(
            item(
                "M03",
                name,
                active=(1, 1, 22, 16),
                holes=tuple(sorted(holes)),
                static=tuple(
                    (*point, detail) for point in sorted(floor | panel_pixels)
                ),
                prefix=(1, 1, 1, 1, 1, 1),
            )
        )
    hidden_gate = replace(panel, initial=False)
    for name, prefix in (("latch-untriggered", (1,)), ("latch-triggered", (5, 1, 1))):
        parts.append(
            item(
                "M07",
                name,
                **common,
                switch=hidden_gate,
                static=divider,
                dynamics="latched",
                signal=(19, 1, detail),
                prefix=prefix,
            )
        )
    for name, hue, mode in (
        ("flash-positive", detail, "flash"),
        ("flash-negative", body, "flash-closed"),
    ):
        parts.append(
            item(
                "M11",
                name,
                **common,
                switch=hidden_gate,
                static=divider,
                dynamics=mode,
                signal=(19, 1, hue),
                prefix=(5, 1),
            )
        )
    still = (3 + shift, 6)
    parts.extend(
        [
            item(
                "M09",
                "undo-first",
                active=(2, 6, 10, 8),
                moves=((1, 1, 0),),
                dynamics="undo-first",
                signal=(17, 1, detail),
                prefix=(1, 7),
            ),
            item(
                "M09",
                "undo-empty",
                active=(2, 6, 10, 8),
                moves=((1, 1, 0),),
                dynamics="undo-all",
                signal=(17, 1, detail),
                prefix=(7,),
            ),
            item(
                "M09",
                "undo-push-and-charge",
                active=(2, 6, 10, 8),
                moves=((1, 1, 0),),
                bodies=(square, obstacle),
                start=push_start,
                pushable=True,
                dynamics="undo-all",
                resource=Resource((18, 1), ((5 + shift, 6), (5 + shift, 7)), detail, 1),
                prefix=(1, 7),
            ),
            item(
                "M10",
                "stationary-charge",
                active=(still[0], 6, still[0] + 2, 8),
                moves=((1, 1, 0),),
                resource=Resource((18, 1), (), detail, 1),
                dynamics="charge-still",
                prefix=(1,),
            ),
            item(
                "M10",
                "stationary-domain",
                active=(still[0], 6, still[0] + 2, 8),
                moves=((1, 1, 0), (2, -1, 0)),
                dynamics="action-domain",
                prefix=(1, 2),
            ),
            item(
                "M10",
                "stationary-identical",
                active=(still[0], 6, still[0] + 2, 8),
                moves=((1, 1, 0),),
                prefix=(1,),
            ),
            item(
                "M12",
                "tracking-landmarks",
                logical_size=(40, 20),
                active=(16, 6, 28, 8),
                start=((18, 6),),
                moves=((1, 1, 0), (2, -1, 0)),
                static=((3, 2, detail), (7, 11, wall), (19, 17, detail)),
                dynamics="tracking",
                prefix=(1, 1, 2),
            ),
            item(
                "M12",
                "tracking-without-landmarks",
                logical_size=(40, 20),
                active=(16, 6, 28, 8),
                start=((18, 6),),
                moves=((1, 1, 0), (2, -1, 0)),
                dynamics="tracking",
                prefix=(1, 1, 2),
            ),
            item(
                "M12",
                "autonomous-peer",
                active=(2, 6, 12, 8),
                start=((3, 6), (6, 10)),
                bodies=(square, ((0, 0, detail),)),
                moves=((1, 1, 0), (2, -1, 0)),
                dynamics="autonomous",
                prefix=(5, 1),
            ),
            item(
                "M14",
                "indistinguishable-gate",
                **common,
                switch=hidden_gate,
                static=divider,
                signal=(16, 1, body),
                prefix=(1, 5, 1),
            ),
            item(
                "M14",
                "indistinguishable-decoy",
                **common,
                switch=hidden_gate,
                static=divider,
                dynamics="decoy-switch",
                signal=(16, 1, body),
                prefix=(1, 5, 1),
            ),
        ]
    )
    return parts


def materialize(root, selected):
    root.mkdir(parents=True, exist_ok=True)
    for scene in selected:
        directory = root / scene.public_id
        directory.mkdir()
        data = directory / "scene.json"
        data.write_text(
            json.dumps(asdict(scene), sort_keys=True) + "\n", encoding="utf-8"
        )
        (directory / "metadata.json").write_text(
            json.dumps(
                {
                    "game_id": scene.public_id,
                    "class_name": "Fixture",
                    "title": "Fixture",
                }
            ),
            encoding="utf-8",
        )
        # The official local loader imports this artifact inside the environment process.
        (directory / "fixture.py").write_text(
            "from pathlib import Path\n"
            "from tddesc_env.bench.game import ShapeGame\n"
            "from tddesc_env.bench.scenario import Scene\n"
            "class Fixture(ShapeGame):\n"
            "    def __init__(self, seed=0):\n"
            f"        super().__init__(Scene.load(Path({str(data.resolve())!r})))\n",
            encoding="utf-8",
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--seed", required=True, type=int)
    args = parser.parse_args()
    materialize(args.output, scenes(read_plan(args.config), args.seed))


if __name__ == "__main__":
    main()
