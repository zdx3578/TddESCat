"""Compare relation-goal regression and the previous full planner on frozen public knowledge."""

from dataclasses import replace
from pathlib import Path
import sys

from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_env.bench.scenario import Switch
from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import supervise
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_composition import collect_training
from tests.bench.check_core_learning import captured_rows
from tests.bench.check_online import load, online_config
from tests.bench.check_sequence_learning import check_scene
from tests.bench.measurement_audit import receipts
from tests.bench.program_audit import frame_sha


def test_scenes(base):
    occupied = {base.background, base.letterbox, *(cell[2] for cell in base.bodies[0])}
    marker, on, off = sorted(set(range(16)) - occupied)[-3:]
    limits = (1, 1, base.logical_size[0] - 1, base.logical_size[1] - 1)
    origin = replace(
        base,
        active=limits,
        moves=((1, 1, 1), (2, 1, -1)),
        switch=Switch((18, 3), (), on, off, False),
    )

    def variant(label, x, y, **changes):
        return replace(
            origin, public_id=origin.public_id + label, start=((x, y),), **changes
        )

    training = []
    for action, repeats in ((1, 7), (2, 9), (5, 7)):
        for i in range(repeats):
            data = variant(f"T{action}{i:02}", 3 + i % 5, 6 + i % 4)
            training.append((data, [action, action] if action == 2 else [action]))
    held = [
        variant(
            "RG01",
            6,
            7,
            static=tuple((11, y, marker) for y in range(3, 12)),
            switch=replace(origin.switch, initial=True),
        ),
        variant("RG02", 8, 9, static=tuple((13, y, marker) for y in range(5, 14))),
    ]
    return training, held, (base.bodies[0][0][2], marker, on, 1)


def capture(root, url, scene, public, prior, goal, *, enabled):
    public.mkdir()
    cfg = public / "agent.toml"
    online_config(
        cfg, root, url, scene, prior=prior, goal=goal, sequences=True, budget=7
    )
    if enabled:
        cfg.write_text(
            cfg.read_text().replace("[planning]", "[planning]\nrelation_goals = true")
        )
    assert supervise(root, cfg, public) == 0, (public / "solver.log").read_text()
    events = check_scene(public, scene)
    rows = captured_rows(public, "checks")
    decisions = captured_rows(public, "decisions")
    assert load(public, "public-run.json")["learned"]["goal"] == "observed"
    return events, rows, decisions


def main(config, run):
    root = Path.cwd()
    runtime = runtime_paths(root)
    task = read_task(config)
    plan = read_plan(task["judge_config"])
    base = next(
        s for s in scenes(plan, plan["training_seeds"][0]) if s.variant == "open-square"
    )
    training, held, goal = test_scenes(base)
    public = run / "public"
    prior = public / "previous"
    games = run / "private/games"
    materialize(games, [*(s for s, _ in training), *held])
    successes = []
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        run / "private/server",
        run / "grade/environment.log",
    ) as (url, _):
        collect_training(
            root,
            runtime,
            url,
            prior,
            [(s, len(actions) + 1) for s, actions in training],
            interventions={s.public_id: actions for s, actions in training},
        )
        for i, scene in enumerate(held):
            location = public / f"held-{i}"
            events, checks, decisions = capture(
                root, url, scene, location, prior, goal, enabled=True
            )
            executions = [
                (check, decision)
                for check, decision in zip(checks, decisions, strict=True)
                if check.get("program")
                and check["program"].get("goal", {}).get("contract")
                == "establishes_goal_relation"
            ]
            assert len(executions) >= 2, [
                (d["reason"], c.get("program")) for c, d in zip(checks, decisions)
            ]
            initial = executions[0][0]["program"]
            first = executions[0][0]
            terminal = executions[-1][0]["program"]
            assert initial["index"] == 1 and terminal["feedback"] == "completed"
            assert first["action"] != initial["baseline_action"]
            assert all(
                set(row["assessments"].values()) == {"supported"}
                for row, _ in executions
            )
            assert initial["definition"] == terminal["definition"]
            regressed = initial["goal"]["regression"]
            assert set(regressed["missing"]) == (
                {"near_marker"} if i == 0 else {"near_marker", "cue_visible"}
            )
            assert "near_marker" in regressed["established"]
            if i:
                assert len(initial["goal"]["continuation"]) == 1
                assert initial["goal"]["continuation"][0]["action"][0] == 5
                assert events[-1]["action"]["id"] == 5
            actual = receipts(location)
            for row, _ in executions:
                assert row["program"]["goal"]["steps"][0]["frame_sha256"] == frame_sha(
                    actual[row["event_ref"]][1]["frame"][-1]
                )
            successes.append(
                dict(
                    definition=initial["definition"],
                    regression=regressed,
                    selected=first["action"],
                    baseline=initial["baseline_action"],
                    commands=[e["action"] for e in events],
                    steps=[row["program"] for row, _ in executions],
                )
            )
        ablation = public / "held-1-baseline"
        base_events, _, base_decisions = capture(
            root, url, held[1], ablation, prior, goal, enabled=False
        )
    assert successes[0]["definition"] == successes[1]["definition"]
    assert successes[0]["regression"]["body"] == successes[1]["regression"]["body"]
    assert (
        successes[0]["regression"]["binding"] != successes[1]["regression"]["binding"]
    )
    assert (
        base_events[1]["action"] == successes[1]["baseline"] != successes[1]["selected"]
    ), (base_events[1]["action"], successes[1]["baseline"], successes[1]["selected"])
    a, b = map(receipts, (public / "held-1", ablation))
    assert next(iter(a.values()))[1]["frame"] == next(iter(b.values()))[1]["frame"]
    trained = [
        load(path, "public-run.json")["learned"]
        for path in (public / "held-1", ablation)
    ]
    assert (
        len(
            {
                value
                for row in trained
                for value in (row["frozen_before"], row["frozen_after"])
            }
        )
        == 1
    )
    result = dict(
        instantiations=successes,
        ablation=[r["action"] for r in base_events],
        ablation_reason=base_decisions[0]["reason"],
    )
    write_json(public / "relation-goal.json", result)
    append_assertion(run, "relation_goal_producer", True, ["public/relation-goal.json"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
