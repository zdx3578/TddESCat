"""Verify learned public motion, an actual counterexample, and the next decisions."""

import json
import sys
from pathlib import Path

from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_env.bench.grade import finite_engine_check, hand_checks, http_trace
from tddesc_tools.contracts import Contracts
from tddesc_tools.isolation import environment_server, isolation_probe
from tddesc_tools.run import (
    append_assertion,
    read_task,
    runtime_paths,
    write_json,
)
from tddesc_tools.stitch import run_worker
from tests.bench.check_evidence import solver_process


def run_julia(root, runtime, public, stage, config, request):
    result = solver_process(
        root,
        runtime,
        public,
        stage,
        config,
        public,
        request,
        script=root / "scripts/motion.jl",
        extra_read=tuple(
            root / path
            for path in (
                "third_party/egg-stitch/UPSTREAM.toml",
                "Cargo.lock",
                "rust-toolchain.toml",
                "config/stitch.toml",
            )
        ),
    )
    (public / (stage[2:] + ".log")).write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(result.stderr)


def records(folder):
    return [json.loads(path.read_bytes()) for path in sorted(folder.glob("*.json"))]


def verify(root, public, routed, by_variant):
    contracts = Contracts(root / "protocol/v1")
    training = public / "training"
    recorded = [
        event for path in training.iterdir() for event in records(path / "events")
    ]
    event_ids = {e["event_id"] for e in recorded if e["action"]["id"] == 1}
    manifest = json.loads((public / "learn-input/manifest.json").read_bytes())
    origins = json.loads((public / "learn-input/origins.json").read_bytes())
    assert {origin["event_ref"] for origin in origins} == event_ids
    assert len(event_ids) == manifest["program_count"] == 8
    assert len({event["intervention_group"] for event in recorded}) == 8
    checkpoints = [
        json.loads((path / "result.json").read_bytes())
        for path in sorted((public / "learn-output").glob("round-*"))
    ]
    discovery = checkpoints[0]
    assert int(discovery["cost"]["final_total"]) < int(
        discovery["cost"]["pre_rewrite_input"]
    )
    assert discovery["definitions"] and len(discovery["calls"]) == len(event_ids)
    library = json.loads((public / "published-library.json").read_bytes())
    assert len(library) == 1
    identity = library[0]["stable_id"]

    episode = public / "control"
    events = records(episode / "events")
    commands = records(episode / "commands")
    predictions = records(episode / "predictions")
    decisions = records(episode / "decisions")
    for event in events:
        contracts.validate("event", event)
    for command in commands:
        contracts.validate("command", command)
    for prediction in predictions:
        contracts.validate("prediction", prediction)
    assert [event["action"]["id"] for event in events] == [0, 1, 5, 1]
    assert [entry["selected"] for entry in decisions] == [1, 5, 1]
    for event, frame in zip(events, routed["panel-toggle"], strict=True):
        response = json.loads((episode / "blobs" / event["response_blob"]).read_bytes())
        assert response["frame"] == [frame]
    checks = records(episode / "checks")
    first, experiment, verified = checks
    assert first["frozen_expected"] == [2, 0] and first["actual"] == [0, 0]
    assert first["status"] == "revised"
    revision = first["revision"]
    assert revision["invalidated"] and revision["event_ref"] == first["event_ref"]
    for step in (experiment, verified):
        assert step["model_version"] == revision["replacement"]
        assert step["definition_ref"] == identity
    assert decisions[1]["candidates"][-1]["reason"] == "condition_false"
    assert verified["status"] == "supported" and verified["actual"] == [2, 0]
    assert predictions[-1]["guard_truth"] is True
    final = json.loads((public / "motion-summary.json").read_bytes())
    mechanism = final["final_claim"]
    assert mechanism["query_scope"] == ["bound_support_displacement"]
    assert (
        mechanism["counterexamples"]
        == mechanism["excluded_counterexamples"]
        == [first["event_ref"]]
    )
    assert first["event_ref"] in mechanism["outstanding"]
    condition = mechanism["condition"]
    assert len(condition) == 1 and condition[0]["kind"] == "component_color"
    panel = by_variant["panel-toggle"].switch.panel
    assert condition[0]["position"] == [8 + panel[0] * 2, 12 + panel[1] * 2]
    assert len(condition[0]["offsets"]) == 16
    heldout, cropped = final["evaluation"]
    assert heldout["status"] == "supported" and heldout["actual"] == [2, 0]
    assert (
        cropped["status"] == "unknown"
        and cropped["reason"] == "condition_evidence_unavailable"
    )
    assert len(records(public / "evaluation-02/events")) == 1
    return {
        "definition": identity,
        "learned_cost": discovery["cost"],
        "independent_training_events": len(event_ids),
        "selected_public_actions": [d["selected"] for d in decisions],
        "counterexample": first["event_ref"],
        "withdrawn_claim": revision["withdrawn"],
        "active_claim": revision["replacement"],
        "condition": condition,
        "heldout": heldout["status"],
        "cropped": cropped["status"],
    }


def main(task_path, run):
    root = Path.cwd()
    run = run.resolve()
    task = read_task(task_path)
    public, private = run / "public", run / "private"
    runtime = runtime_paths(root)
    plan = read_plan(task["judge_config"])
    selected = scenes(plan, plan["training_seeds"][0])
    by_variant = {scene.variant: scene for scene in selected}
    training_names = ("panel-open", "panel-unrelated")
    targets = ("panel-toggle", "panel-position-heldout", "panel-cropped-closed")
    for name in (*training_names, *targets):
        counts = finite_engine_check(by_variant[name])
        assert counts["transitions"] > 0
    materialize(private / "games", selected)
    request = public / "request.json"
    write_json(
        request,
        {
            "training_games": [
                by_variant[name].public_id for name in training_names for _ in range(4)
            ],
            "control_game": by_variant[targets[0]].public_id,
            "evaluation_games": [by_variant[name].public_id for name in targets[1:]],
        },
    )
    template = task["agent_config"].read_text()
    config = public / "agent.toml"
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        private / "games",
        private / "server",
        private / "environment.log",
    ) as (url, pid):
        checks = isolation_probe(
            root,
            url,
            private / "games" / by_variant[targets[0]].public_id / "scene.json",
            private,
            pid,
        )
        write_json(private / "isolation.json", checks)
        routed = {}
        for scene in selected:
            frames, trace = http_trace(url, scene)
            routed[scene.variant] = frames
            write_json(private / "traces" / (scene.variant + ".json"), trace)
        hand_checks(by_variant, routed)
        config.write_text(
            template.replace("http://127.0.0.1:43191", url).replace(
                "max_public_commands = 2", "max_public_commands = 4"
            )
        )
        run_julia(root, runtime, public, "--collect", config, request)
        code = run_worker(
            root,
            public / "learn-input",
            public / "learn-output",
            root / "target/release/tddesc-stitch",
        )
        if code != 0:
            raise RuntimeError(f"Actual E-Stitch stopped with status {code}")
        run_julia(root, runtime, public, "--control", config, request)
    result = verify(root, public, routed, by_variant)
    write_json(public / "verified-motion.json", result)
    append_assertion(
        run,
        "conditional_motion",
        True,
        [
            "public/verified-motion.json",
            "public/control/checks",
            "public/learn-output",
            "public/motion-summary.json",
            "private/isolation.json",
        ],
    )


if __name__ == "__main__":
    main(*(Path(arg) for arg in sys.argv[1:]))
