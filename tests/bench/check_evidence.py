"""Capture and replay real responses from the verified local fixture."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

from tddesc_env.bench import reference
from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_tools.contracts import Contracts
from tddesc_tools.isolation import environment_server, isolation_probe, sandbox
from tddesc_tools.run import (
    append_assertion,
    julia_command,
    read_task,
    runtime_paths,
    write_json,
)


def solver_process(root, runtime, public, *args, offline=False):
    script = root / "scripts/run.jl"
    julia = Path(runtime["julia"]["executable"]).resolve().parents[1]
    project = root / "julia/TddESCat"
    cache = Path(runtime["julia_cache"]["depot"])
    global_depot = Path.home() / ".julia"
    installed = tuple(
        path
        for path in (
            global_depot / "packages",
            global_depot / "artifacts",
            global_depot / "compiled",
        )
        if path.is_dir()
    )
    command = julia_command(root, runtime, script, *args)
    command = sandbox(
        command,
        read=(julia, project, script, cache, *installed),
        write=(public,),
        variables={
            "JULIA_LOAD_PATH": "@:@stdlib",
            "JULIA_DEPOT_PATH": f"/tmp/julia:{cache}:{global_depot}:",
        },
        offline=offline,
    )
    return subprocess.run(command, capture_output=True, text=True, timeout=155)


def assertions(public, scene, contracts):
    commands = sorted(
        (json.loads(p.read_bytes()) for p in (public / "commands").glob("*.json")),
        key=lambda item: item["sequence"],
    )
    events = sorted(
        (json.loads(p.read_bytes()) for p in (public / "events").glob("*.json")),
        key=lambda item: item["sequence"],
    )
    assert [(c["kind"], c["completion"]) for c in commands] == [
        ("open_scorecard", "confirmed"),
        ("reset", "confirmed"),
        ("action", "confirmed"),
        ("close_scorecard", "confirmed"),
    ]
    assert [e["action"] for e in events] == [{"id": 0}, {"id": 1}]
    assert (
        events[0]["before_ref"] is None
        and events[1]["before_ref"] == events[0]["event_id"]
    )
    for command in commands:
        contracts.validate("command", command)
        assert (
            hashlib.sha256(command["request_body"].encode()).hexdigest()
            == command["request_sha256"]
        )
    for i, event in enumerate(events):
        contracts.validate("event", event)
        payload = (public / "blobs" / event["response_blob"]).read_bytes()
        body = json.loads(payload)
        assert hashlib.sha256(payload).hexdigest() == event["response_blob"]
        state = scene.start if i == 0 else reference.transition(scene, scene.start, 1)
        assert body["frame"] == [reference.render(scene, state)]
        assert event["frame_shapes"] == [[64, 64]]
        prediction_path = public / "predictions" / f"{event['prediction_ref']}.json"
        prediction = json.loads(prediction_path.read_bytes())
        contracts.validate("prediction", prediction)
        assert prediction["guard_truth"] == "unknown"
        assert prediction["created_before_command"]["sequence"] == event["sequence"]
    return events


def main(config, run_dir):
    root = Path.cwd()
    runtime = runtime_paths(root)
    task = read_task(config)
    plan = read_plan(task["judge_config"])
    scene = next(
        s for s in scenes(plan, plan["training_seeds"][0]) if s.variant == "open-wide"
    )
    games = run_dir / "private/games"
    materialize(games, [scene])
    public = run_dir / "public"
    local_config = public / "agent.toml"
    log = run_dir / "grade/environment.log"
    template = task["agent_config"].read_text(encoding="utf-8")
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        run_dir / "private/server",
        log,
    ) as (url, pid):
        checks = isolation_probe(
            root, url, games / scene.public_id / "scene.json", run_dir / "private", pid
        )
        write_json(run_dir / "grade/isolation.json", checks)
        local_config.write_text(
            template.replace("http://127.0.0.1:43191", url), encoding="utf-8"
        )
        captured = solver_process(
            root, runtime, public, "--config", local_config, "--public-dir", public
        )
        (run_dir / "grade/capture.log").write_text(
            captured.stdout + captured.stderr, encoding="utf-8"
        )
        assert captured.returncode == 0, captured.stderr
        assert json.loads(captured.stdout.splitlines()[-1])["recorded"] == 2
    assert log.read_text(encoding="utf-8").count("POST /api/cmd/") == 2
    contracts = Contracts(root / "protocol/v1")
    events = assertions(public, scene, contracts)
    command_bytes = {p: p.read_bytes() for p in (public / "commands").glob("*.json")}
    results = []
    for expected in (2, 0):
        replayed = solver_process(
            root, runtime, public, "--replay", public, offline=True
        )
        assert replayed.returncode == 0, replayed.stderr
        result = json.loads(replayed.stdout.splitlines()[-1])
        assert result["applied"] == expected and result["total"] == 2
        results.append(result)
    assert all(path.read_bytes() == body for path, body in command_bytes.items())
    report = json.loads((public / "replay.json").read_bytes())
    assert report["through_event"] == events[-1]["event_id"]
    changed = report["applied_events"][-1]["transitions"][0]
    # Hand geometry gives two outgoing and two entering logical cells, each 2x2 on screen.
    assert len(changed) == 16
    assert {(p["x"], p["y"]) for p in changed} == {
        (x, y) for x in (14, 15, 20, 21) for y in (24, 25, 26, 27)
    }
    write_json(run_dir / "grade/replay_checks.json", results)
    append_assertion(
        run_dir,
        "capture_replay",
        True,
        [
            "public/events.jsonl",
            "public/replay.json",
            "grade/capture.log",
            "grade/replay_checks.json",
        ],
    )


if __name__ == "__main__":
    main(*(Path(arg) for arg in sys.argv[1:]))
