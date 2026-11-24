"""Measure a learned eight-step program on a separate public layout."""

import sys
from dataclasses import replace
from pathlib import Path

from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import supervise
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_composition import collect_training
from tests.bench.check_core_learning import captured_rows
from tests.bench.check_online import load, online_config
from tests.bench.check_sequence_learning import check_scene, inspect_learning


def main(config, run):
    root = Path.cwd()
    task = read_task(config)
    plan = read_plan(task["judge_config"])
    runtime = runtime_paths(root)
    base = next(
        s for s in scenes(plan, plan["training_seeds"][0]) if s.variant == "open-square"
    )
    base = replace(base, moves=((1, 1, 0), (2, -1, 0)))
    training = []
    interventions = {}
    for length, count in ((2, 6), (4, 12), (8, 20)):
        for i in range(count):
            scene = replace(
                base,
                public_id=base.public_id + f"D{length}{i:02}",
                start=((5 + i % 5, 5 + i // 5),),
            )
            training.append((scene, length + 1))
            interventions[scene.public_id] = [2, 1] * (length // 2)
    held = replace(base, public_id=base.public_id + "D99", start=((10, 11),))
    games = run / "private/games"
    materialize(games, [*(scene for scene, _ in training), held])
    public = run / "public"
    prior = public / "training"
    target = public / "held-out"
    target.mkdir()
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        run / "private/server",
        run / "grade/environment.log",
    ) as (url, _):
        collect_training(
            root, runtime, url, prior, training, interventions=interventions
        )
        cfg = target / "agent.toml"
        online_config(
            cfg,
            root,
            url,
            held,
            budget=9,
            prior=prior,
            sequences=True,
            policy_file=task["experiment_config"],
            learning_memory_bytes=12 * 1024**3,
        )
        assert supervise(root, cfg, target) == 0, (target / "solver.log").read_text()
    events = check_scene(target, held)
    assert len(events) == 9
    phases = inspect_learning(target, prior, expected_lengths=(2, 4, 8))
    assert [len(phase["sources"]) for phase in phases] == [12, 48, 160]
    older, latest = phases[-2:]
    bundle = load(target, f"publication/{latest['publication']}.json")
    definitions = {
        entry["stable_id"]: entry["definition"] for entry in bundle["library"]
    }
    checks = captured_rows(target, "checks")
    consumed = checks[0]["program"]["definition"]
    assert consumed in latest["programs"]
    assert set(definitions[consumed]["dependencies"]) & set(older["programs"])
    assert [r["action"]["id"] for r in checks] == [2, 1] * 4
    assert all(r["program"]["definition"] == consumed for r in checks)
    assert [r["program"]["index"] for r in checks] == list(range(1, 9))
    assert all(
        r["program"]["length"] == 8 and r["program"]["depth"] >= 5 for r in checks
    )
    assert all(set(r["assessments"].values()) == {"supported"} for r in checks)
    assert checks[-1]["program"]["feedback"] == "completed"
    result = load(target, "public-run.json")["learned"]
    assert result["frozen_before"] == result["frozen_after"]
    assert result["publications"] == []
    write_json(
        public / "eight-step-consumption.json", {"learning": phases, "checks": checks}
    )
    append_assertion(
        run, "eight_step_program", True, ["public/eight-step-consumption.json"]
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
