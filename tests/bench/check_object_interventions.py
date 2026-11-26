"""Exercise cold acquisition, transfer and revision of an object-bound goal."""

import json
from pathlib import Path
import sys
from types import SimpleNamespace

from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import supervise
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_online import online_config
from tests.bench.measurement_audit import receipts


def materialize(directory):
    game = "o679-24a3ea8d"
    folder = directory / game
    folder.mkdir(parents=True)
    write_json(
        folder / "metadata.json",
        dict(game_id=game, class_name="Fixture", title="Fixture"),
    )
    family = (
        tuple((x, y) for x in range(3) for y in range(3)),
        ((0, 0), (0, 1), (0, 2), (1, 2), (2, 2)),
        ((0, 0), (1, 0), (2, 0), (0, 1), (2, 1), (0, 2), (2, 2)),
        ((0, 1), (1, 0), (1, 1), (1, 2), (2, 1)),
    )
    rows = (
        ((11, 10), (26, 35), (51, 30), 3),
        ((19, 22), (48, 12), (34, 45), 8),
        ((13, 36), (55, 43), (39, 17), 11),
        ((24, 35), (9, 29), (41, 13), 6),
    )
    slides = []
    for index, (shape, row) in enumerate(zip(family, rows, strict=True)):
        first, second, single, color = row
        supports = [tuple((x + u, y + v) for x, y in shape) for u, v in (first, second)]
        supports.append(tuple((single[0], single[1] + i) for i in range(4)))
        positive = (2,) if index == 3 else (0, 1)
        slides.append((supports, positive, color))
    (folder / "fixture.py").write_text(
        "import numpy as np\nfrom arcengine import ARCBaseGame, Camera, Level, Sprite\n"
        f"SLIDES = {slides!r}\n"
        "class Fixture(ARCBaseGame):\n"
        "    def __init__(self, seed=0):\n"
        "        levels = []\n"
        "        for supports, _, color in SLIDES:\n"
        "            frame = np.zeros((64, 64), dtype=np.int8)\n"
        "            for support in supports:\n"
        "                for x, y in support:\n"
        "                    frame[y, x] = color\n"
        "            levels.append(Level(sprites=[Sprite(frame, name='public')]))\n"
        f"        super().__init__({game!r}, levels, camera=Camera(width=64, height=64),\n"
        "            available_actions=[6], win_score=len(levels), seed=seed)\n"
        "    def step(self):\n"
        "        if self.action.id.value == 6:\n"
        "            supports, positive, _ = SLIDES[self.level_index]\n"
        "            target = (self.action.data['x'], self.action.data['y'])\n"
        "            if any(target in supports[i] for i in positive):\n"
        "                self.next_level()\n"
        "        self.complete_action()\n",
        encoding="utf-8",
    )
    return SimpleNamespace(public_id=game), slides


def read(path):
    return json.loads(path.read_bytes())


def audit(public, scenes):
    trace = receipts(public)
    actions = []
    for event, result in trace.values():
        if not event["action"]["id"]:
            continue
        ref = event["command_ref"] + ".json"
        before = trace[event["before_ref"]][1]
        level = before["levels_completed"]
        decision = read(public / "decisions" / ref)
        check = read(public / "checks" / ref)
        prediction = read(public / "predictions" / ref)
        intervention = decision["intervention"]
        feedback = check["intervention_feedback"]
        xy = tuple(event["action"][key] for key in ("x", "y"))
        support, positive, color = scenes[level]
        matched = [i for i, shape in enumerate(support) if xy in shape]
        advanced = result["levels_completed"] > level
        assert advanced == any(i in positive for i in matched)
        assert (
            feedback["advanced"] == advanced and feedback["event"] == event["event_id"]
        )
        if intervention["probe"] == "representative":
            assert len(matched) == 1 and intervention["binding"]["point"] == list(xy)
            assert before["frame"][-1][xy[1]][xy[0]] == color
        else:
            assert (
                intervention["probe"] == "coordinate" and intervention["goal"] is None
            )
        goal = intervention["goal"]
        if goal:
            assert prediction["predicted_values"]["public_advancement"] is True
            assert set(goal["reads"]) <= set(prediction["event_reads"])
            assert all(
                trace[ref][0]["sequence"] < event["sequence"] for ref in goal["reads"]
            )
            assert any(row["variable"] == "shape_multiplicity" for row in goal["rules"])
        actions.append(
            dict(
                level=level,
                point=xy,
                reason=decision["reason"],
                outcome=feedback["result"],
                event=event["event_id"],
            )
        )
    assert list(trace.values())[-1][1]["state"] == "WIN"
    assert [row["outcome"] for row in actions if row["level"] in (0, 1)] == [
        "observed"
    ] * 4
    assert [row["outcome"] for row in actions if row["level"] == 2] == ["established"]
    last = [row for row in actions if row["level"] == 3]
    assert last[0]["outcome"] == "refuted"
    assert all(row["outcome"] == "observed" for row in last[1:])
    assert last[0]["point"] != last[-1]["point"]
    assert last[-1]["reason"] == "probe_visible_object"
    return actions


def main(config, run):
    root = Path.cwd()
    task, runtime = read_task(config), runtime_paths(root)
    folder = run / "private/games"
    game, scenes = materialize(folder)
    public = run / "public"
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        folder,
        run / "private/server",
        run / "grade/environment.log",
    ) as (url, _):
        cfg = public / "agent.toml"
        online_config(
            cfg,
            root,
            url,
            game,
            planning=True,
            budget=20,
            sequences=True,
            batch=8,
            background_search=True,
        )
        cfg.write_text(cfg.read_text() + "autonomous = true\nrelation_goals = true\n")
        assert supervise(root, cfg, public) == 0, (public / "solver.log").read_text()
    rows = audit(public, scenes)
    write_json(public / "object-interventions.json", dict(actions=rows, levels=4))
    append_assertion(
        run,
        "object_intervention_advancement",
        True,
        ["public/object-interventions.json"],
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
