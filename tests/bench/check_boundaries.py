"""Check the incomplete cases through the public solver with an empty library."""

import sys
from pathlib import Path

from tddesc_env.bench import reference
from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_tools.isolation import environment_server
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_core_learning import captured_rows
from tests.bench.check_evidence import solver_process
from tests.bench.check_online import load, online_config

BOUNDARIES = {
    "M03": ("walk-narrow-bridge", "walk-wide-bridge"),
    "M07": ("latch-triggered",),
    "M09": ("undo-empty", "undo-push-and-charge"),
    "M10": ("stationary-domain", "stationary-charge", "stationary-identical"),
    "M11": ("flash-positive", "flash-negative"),
    "M12": ("tracking-landmarks", "tracking-without-landmarks", "autonomous-peer"),
    "M13": ("bridge-and-diagonal", "multicolor-rigid", "touch-and-separate"),
    "M14": ("indistinguishable-gate", "indistinguishable-decoy"),
}


def assess_episode(episode, scene):
    records = captured_rows(episode, "checks")
    decisions = captured_rows(episode, "decisions")
    assert records and len(records) == len(decisions)
    expected = scene.start_state
    public_prefix = []
    for event in captured_rows(episode, "events"):
        observation = load(episode, "blobs/" + event["response_blob"])
        action = event["action"]
        assert action["id"] == 0 or action["id"] in reference.available_actions(
            scene, expected
        )
        command = (6, action["x"], action["y"]) if action["id"] == 6 else action["id"]
        next_state = reference.transition(scene, expected, command)
        assert observation["frame"] == reference.render_response(
            scene, expected, command, next_state
        )
        assert observation["available_actions"] == list(
            reference.available_actions(scene, next_state)
        )
        expected = next_state
        public_prefix.append(
            {
                key: observation[key]
                for key in (
                    "frame",
                    "state",
                    "available_actions",
                    "levels_completed",
                    "win_levels",
                )
            }
            | {"action": action}
        )
    for row in records:
        assert not row["assessments"] and not row["expected"]
        assert row["coverage"]["qualification"] == "unresolved"
        assert row["coverage"]["obligations"]
    assert all(
        row["guard_truth"] == "unknown" and not row["predicted_values"]
        for row in captured_rows(episode, "predictions")
    )
    if scene.variant == "stationary-domain":
        assert public_prefix[0]["frame"] == public_prefix[1]["frame"]
        domain_change = records[0]["evidence"]["public_delta"]["available_actions"]
        assert domain_change == {"before": [1, 2], "after": [2]}
        assert decisions[1]["action"] == {"id": 2}
    if scene.case in ("M07", "M11"):
        flashed = next(row for row in records if row["action"]["id"] == 5)
        trace = flashed["evidence"]["public_delta"]["response_trace"]
        assert [row["response_frame"] for row in trace] == [0, 1, 2]
        assert any(row["changed_pixels"] > 0 for row in trace)
        assert (
            "intermediate_frames_require_separate_interpretation"
            in flashed["coverage"]["obligations"]
        )
    if scene.variant == "undo-push-and-charge":
        attempted = [row["action"]["id"] for row in records]
        assert attempted[0] == 1 and 7 in attempted
        before = public_prefix[0]["frame"][-1]
        after_undo = public_prefix[attempted.index(7) + 1]["frame"][-1]
        assert before != after_undo
    normalized = [
        {
            "action": row["action"],
            "reason": row["reason"],
            "candidates": row["candidates"],
        }
        for row in decisions
    ]
    return {
        "observations": public_prefix,
        "decisions": normalized,
        "events": [row["event_ref"] for row in records],
    }


def main(config, run):
    root = Path.cwd()
    runtime = runtime_paths(root)
    task = read_task(config)
    plan = read_plan(task["judge_config"])
    by_name = {s.variant: s for s in scenes(plan, plan["evaluation_seeds"][0])}
    selected = {
        case: [by_name[name] for name in names] for case, names in BOUNDARIES.items()
    }
    public = run / "public"
    private = run / "private"
    materialize(
        private / "games", [scene for cases in selected.values() for scene in cases]
    )
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        private / "games",
        private / "server",
        run / "grade/environment.log",
    ) as (url, _):
        inputs = []
        for cases in selected.values():
            for scene in cases:
                episode = public / scene.variant
                episode.mkdir()
                agent = episode / "agent.toml"
                online_config(
                    agent,
                    root,
                    url,
                    scene,
                    budget=3 if scene.case == "M14" else 4,
                    collection=True,
                )
                inputs.append({"config": str(agent), "public": str(episode)})
        roster = public / "public-inputs.json"
        write_json(roster, inputs)
        proc = solver_process(
            root,
            runtime,
            public,
            str(roster),
            script=root / "tests/julia/collect_public.jl",
            extra_read=(root / "scripts/run.jl", root / "config/stitch.toml"),
        )
        (run / "grade/solver.log").write_text(proc.stdout + proc.stderr)
        assert proc.returncode == 0, proc.stderr
    for case, cases in selected.items():
        rows = {
            scene.variant: assess_episode(public / scene.variant, scene)
            for scene in cases
        }
        if case == "M14":
            left, right = rows.values()
            assert left["observations"][:2] == right["observations"][:2]
            assert left["decisions"] == right["decisions"]
            assert left["observations"][2] != right["observations"][2]
        write_json(public / (case + ".json"), rows)
        append_assertion(run, case, True, [f"public/{case}.json", "grade/solver.log"])


if __name__ == "__main__":
    main(*(Path(arg) for arg in sys.argv[1:]))
