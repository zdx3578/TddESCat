"""Generate paired, deterministic private fixtures with opaque public IDs."""

import argparse
import json
import random
import tomllib
from dataclasses import asdict, replace
from hashlib import sha256
from pathlib import Path

from .scenario import Scene

CASES = ("M01", "M02", "M13")
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
