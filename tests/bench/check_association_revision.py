"""Verify that actual feedback constructs a condition and changes the next action."""

import sys
from dataclasses import replace
from pathlib import Path

from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_env.bench.grade import finite_engine_check
from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import supervise
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_association import fixture
from tests.bench.check_composition import collect_training
from tests.bench.check_core_learning import captured_rows
from tests.bench.check_online import load, online_config
from tests.bench.check_sequence_learning import check_scene


def main(config, run):
    root = Path.cwd()
    runtime = runtime_paths(root)
    task = read_task(config)
    plan = read_plan(task["judge_config"])
    base = next(
        scene
        for scene in scenes(plan, plan["training_seeds"][0])
        if scene.variant == "open-square"
    )
    used = {base.background, base.letterbox, base.bodies[0][0][2]}
    marker, decoy, *_ = sorted(set(range(16)) - used)
    training = [fixture(base, i, 4 + i, 6, marker, decoy, True) for i in range(4)]
    held = replace(
        training[0],
        public_id=base.public_id + "81",
        start=((8, 8),),
        static=((10, 7, marker), (8, 7, decoy)),
    )
    games = run / "private/games"
    materialize(games, [*training, held])
    finite_engine_check(held)
    public = run / "public"
    prior = public / "training"
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
            [(scene, 2) for scene in training],
            interventions={
                scene.public_id: [1 if i == 0 else 2]
                for i, scene in enumerate(training)
            },
        )
        path = public / "episode"
        path.mkdir()
        cfg = path / "agent.toml"
        online_config(
            cfg,
            root,
            url,
            held,
            budget=4,
            prior=prior,
            adapt=True,
            association=True,
            batch=8,
        )
        assert supervise(root, cfg, path) == 0, (path / "solver.log").read_text()
    events = check_scene(path, held)
    decisions = captured_rows(path, "decisions")
    checks = captured_rows(path, "checks")
    assert [row["action"]["id"] for row in decisions] == [1, 2, 1]
    assert "refuted" in checks[0]["assessments"].values()
    assert checks[0]["revisions"] and checks[0]["event_ref"] == events[1]["event_id"]
    assert set(checks[1]["assessments"].values()) == {"supported"}
    assert set(checks[2]["assessments"].values()) == {"supported"}
    refusal = next(
        item for item in decisions[1]["candidates"] if item["action"]["id"] == 1
    )
    assert refusal["reason"] == "learned_condition_false"
    assert decisions[2]["relations"]
    certificate = decisions[2]["relations"][0]["certificate_sha256"]
    evidence = load(path, f"publication/constructed/{certificate}.json")["certificate"]
    assert events[1]["event_id"] in evidence["recalled_events"]
    assert events[1]["event_id"] in checks[2]["read_events"]
    write_json(
        public / "revision.json",
        {
            "counterexample": events[1]["event_id"],
            "condition": decisions[2]["relations"],
            "refused": refusal,
            "revision": checks[0]["revisions"],
            "restored": events[-1]["event_id"],
            "actions": [row["action"] for row in decisions],
        },
    )
    append_assertion(run, "A07", True, ["public/revision.json"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
