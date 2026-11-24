"""Learn an action condition from an earlier confirmed response's middle frame."""

import sys
from dataclasses import replace
from pathlib import Path

from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_env.bench.reference import render_response, transition
from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import supervise
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_composition import collect_training
from tests.bench.check_core_learning import captured_rows
from tests.bench.check_online import load, online_config


def referee(path, scene):
    state = scene.start_state
    public = []
    for event in captured_rows(path, "events"):
        command = event["action"]["id"]
        outcome = transition(scene, state, command)
        frames = load(path, "blobs/" + event["response_blob"])["frame"]
        assert frames == render_response(scene, state, command, outcome)
        public.append((event, frames))
        state = outcome
    return public


def main(config, run):
    root = Path.cwd()
    task = read_task(config)
    plan = read_plan(task["judge_config"])
    runtime = runtime_paths(root)
    base = {
        scene.variant: scene
        for scene in scenes(plan, plan["training_seeds"][0])
        if scene.variant in ("flash-positive", "flash-negative")
    }
    previous = [
        replace(
            scene,
            public_id=scene.public_id + f"T{i:02}",
            signal=(19, 1 + i, scene.signal[2]),
        )
        for scene in base.values()
        for i in range(4)
    ]
    held = {
        name: replace(
            scene, public_id=scene.public_id + "T99", signal=(18, 4, scene.signal[2])
        )
        for name, scene in base.items()
    }
    games = run / "private/games"
    materialize(games, [*previous, *held.values()])
    public = run / "public"
    prior = public / "training"
    result = {}
    traces = {}
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
            [(scene, 3) for scene in previous],
            interventions={scene.public_id: [5, 1] for scene in previous},
        )
        for episode, scene in zip(
            sorted(prior.glob("episode-*")), previous, strict=True
        ):
            events = referee(episode, scene)
            assert len(events) == 3 and len(events[1][1]) == 3
            assert events[1][0]["action"] == {"id": 5}
        for name, scene in held.items():
            path = public / name
            path.mkdir()
            cfg = path / "agent.toml"
            online_config(cfg, root, url, scene, budget=3, prior=prior)
            assert supervise(root, cfg, path) == 0, (path / "solver.log").read_text()
            events = referee(path, scene)
            assert len(events) == 3 and events[1][0]["action"] == {"id": 5}
            assert events[0][1][-1] == events[1][1][-1]
            traces[name] = events[1][1]
            checks = captured_rows(path, "checks")
            decisions = captured_rows(path, "decisions")
            after = decisions[-1]
            assert after["before_ref"] == events[1][0]["event_id"]
            first_action = next(
                candidate
                for candidate in after["candidates"]
                if candidate["action"] == {"id": 1}
            )
            if name == "flash-positive":
                assert checks[-1]["action"] == {"id": 1}
                assert set(checks[-1]["assessments"].values()) == {"supported"}
                assert events[1][0]["event_id"] in checks[-1]["read_events"]
                assert events[-1][0]["event_id"] not in checks[-1]["read_events"]
                assert any(
                    atom["kind"] == "previous_response_transient_color"
                    for atom in after["condition_atoms"]
                )
            else:
                assert "learned_condition_false" in first_action["reason"]
                assert not checks[-1]["expected"]
            learned = load(path, "public-run.json")["learned"]
            assert learned["frozen_before"] == learned["frozen_after"]
            result[name] = {
                "trace_event": events[1][0]["event_id"],
                "check": checks[-1],
                "candidate": first_action,
            }
    positive, negative = (traces[s] for s in ("flash-positive", "flash-negative"))
    assert (
        positive[0] == negative[0]
        and positive[1] != negative[1]
        and positive[2] == negative[2]
    )
    write_json(public / "trace-learning.json", result)
    append_assertion(
        run, "learned_intermediate_response", True, ["public/trace-learning.json"]
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
