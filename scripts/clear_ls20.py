"""Run the ls20 planner against the official offline HTTP environment and verify WIN."""

import argparse
import json
import subprocess
import tempfile
from hashlib import sha256
from importlib.metadata import version
from pathlib import Path

from tddesc_tools.isolation import environment_server, isolation_probe, solver_sandbox
from tddesc_tools.run import (
    julia_command,
    runtime_paths,
    write_artifact_index,
    write_json,
)

ROOT = Path(__file__).resolve().parents[1]
GAME = "ls20-9607627b"
LEVELS = 7


def read_json(path):
    return json.loads(path.read_bytes())


def source_identity(bundle):
    catalog = bundle / "offline_public_games_manifest.json"
    game_dir = bundle / "environment_files/ls20/9607627b"
    metadata = game_dir / "metadata.json"
    game_file = game_dir / "ls20.py"
    if read_json(metadata)["game_id"] != GAME:
        raise ValueError(f"Expected the original public version {GAME}")
    return game_file, {
        "environment": "official_offline_http",
        "game_id": GAME,
        "game_source_sha256": sha256(game_file.read_bytes()).hexdigest(),
        "metadata_sha256": sha256(metadata.read_bytes()).hexdigest(),
        "catalog_sha256": sha256(catalog.read_bytes()).hexdigest(),
        "toolkit": version("arc-agi"),
        "engine": version("arcengine"),
    }


def verified_scorecard(public, guid):
    commands = [
        read_json(path) for path in sorted((public / "commands").glob("*.json"))
    ]
    if not commands or any(row["completion"] != "confirmed" for row in commands):
        return None
    last = commands[-1]
    if last["kind"] != "close_scorecard":
        return None
    response = read_json(public / "blobs" / last["response_blob"])
    for game in response["environments"]:
        if (
            game["id"] == GAME
            and game["completed"]
            and game["levels_completed"] == LEVELS
        ):
            for play in game["runs"]:
                if play["guid"] == guid and play["state"] == "WIN":
                    return {
                        "response_sha256": last["response_blob"],
                        "actions": play["actions"],
                        "in_level_resets": play["resets"],
                        "score": play["score"],
                    }
    return None


def verify_receipts(public, capture_status, replay_status):
    if replay_status:
        return {"passed": False, "capture": capture_status, "replay": replay_status}
    log = read_json(public / "replay.json")
    applied = log["applied_events"]
    transitions = []
    completed = 0
    moves = 0
    resets = 0
    receipt = {}
    for item in applied:
        receipt = read_json(public / "blobs" / item["response_blob"])
        if receipt["game_id"] != GAME or receipt["win_levels"] != LEVELS:
            raise ValueError("Native receipt has the wrong game or level count")
        if receipt["action_input"]["id"] == 0:
            resets += 1
        else:
            moves += 1
        after = receipt["levels_completed"]
        if after != completed:
            transitions.append(
                {
                    "completed": after,
                    "event": item["event_id"],
                    "response_sha256": item["response_blob"],
                    "action_count": moves,
                }
            )
            completed = after
    scorecard = verified_scorecard(public, receipt["guid"]) if receipt else None
    passed = (
        capture_status == 0
        and [row["completed"] for row in transitions] == list(range(1, LEVELS + 1))
        and receipt.get("state") == "WIN"
        and scorecard is not None
        and log["through_event"] == applied[-1]["event_id"]
    )
    return {
        "passed": passed,
        "state": receipt.get("state"),
        "levels_completed": completed,
        "actions": moves,
        "resets": resets,
        "events": len(applied),
        "frames": sum(item["frame_count"] for item in applied),
        "scorecard": scorecard,
        "through_event": log["through_event"],
        "level_transitions": transitions,
        "capture": capture_status,
        "replay": replay_status,
    }


def run(bundle, output):
    game_file, source = source_identity(bundle)
    runtime = runtime_paths(ROOT)
    public = output / "public"
    grade = output / "grade"
    private = output / "private"
    public.mkdir()
    grade.mkdir()
    write_json(public / "arc-source.json", source)
    script = ROOT / "scripts/run.jl"
    config = public / "agent.toml"

    def launch(command, *, offline=False):
        return solver_sandbox(
            ROOT,
            runtime,
            command,
            public,
            script=script,
            extra_read=() if offline else (config,),
            offline=offline,
        )

    with environment_server(
        ROOT,
        runtime,
        ROOT / "config/bench_server.toml",
        bundle / "environment_files",
        private / "server",
        grade / "environment.log",
    ) as (url, pid):
        config.write_text(
            (ROOT / "config/ls20_clear.toml")
            .read_text(encoding="utf-8")
            .replace("http://127.0.0.1:0", url),
            encoding="utf-8",
        )
        probe = isolation_probe(ROOT, url, game_file, private, pid, launch=launch)
        write_json(public / "solver-isolation.json", probe)
        command = julia_command(
            ROOT, runtime, script, "--config", str(config), "--public-dir", str(public)
        )
        with (grade / "capture.log").open("wb") as log:
            capture = subprocess.run(
                launch(
                    [
                        "/usr/bin/time",
                        "-v",
                        "-o",
                        str(public / "solver-usage.txt"),
                        *command,
                    ]
                ),
                stdout=log,
                stderr=subprocess.STDOUT,
                check=False,
            )

    command = julia_command(ROOT, runtime, script, "--replay", str(public))
    with (grade / "replay.log").open("wb") as log:
        replay = subprocess.run(
            launch(command, offline=True),
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    report = verify_receipts(public, capture.returncode, replay.returncode)
    write_json(public / "ls20-verification.json", report)
    write_artifact_index(output)
    print(json.dumps({"run": str(output), **report}, ensure_ascii=False))
    return int(not report["passed"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline-bundle", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.output is None:
        base = ROOT / "runs"
        base.mkdir(exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix="ls20-clear-", dir=base))
    else:
        output = args.output.resolve()
        output.mkdir(parents=True)
    return run(args.offline_bundle.resolve(), output)


if __name__ == "__main__":
    raise SystemExit(main())
