"""Exercise each versioned public game over the official local HTTP interface."""

import json
import sys
from hashlib import sha256
from importlib.metadata import version
from pathlib import Path

import requests
from jsonschema import ValidationError

from tddesc_tools.contracts import Contracts
from tddesc_tools.isolation import environment_server, isolation_probe, solver_sandbox
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_evidence import solver_process


def load(path):
    return json.loads(path.read_bytes())


def digest(path):
    return sha256(path.read_bytes()).hexdigest()


def source_manifest(catalog, games, ids):
    manifest = load(catalog)
    bases = {game_id.split("-")[0] for game_id in ids}
    for label in ("target", "available"):
        assert manifest[f"{label}_count"] == len(ids)
        assert set(manifest[f"{label}_games"]) == bases
    sources = {}
    for game_id in ids:
        base, revision = game_id.split("-")
        game = games / base / revision
        metadata = game / "metadata.json"
        assert load(metadata)["game_id"] == game_id, game_id
        sources[game_id] = {
            "metadata_sha256": digest(metadata),
            "source_sha256": digest(game / f"{base}.py"),
        }
    return {
        "catalog_sha256": digest(catalog),
        "toolkit": version("arc-agi"),
        "engine": version("arcengine"),
        "games": sources,
    }


def write_episode_config(path, url, game_id, actions_per_game):
    path.write_text(
        f"""schema_version = 1
run_name = "{game_id}"
run_root = "."

[environment]
base_url = "{url}"
competition_mode = false
game_selection = "explicit"
game_id = "{game_id}"
connect_timeout_seconds = 2
request_timeout_seconds = 10

[execution]
max_public_commands = {actions_per_game + 1}
one_inflight_per_guid = true
post_retry = false
redirect = false
memory_enforcement = "cooperative"
""",
        encoding="utf-8",
    )


def run_batch(root, runtime, run, mode, script, entry):
    public = run / "public"
    proc = solver_process(
        root,
        runtime,
        public,
        mode,
        public / "episodes.json",
        offline=mode == "replay",
        script=script,
        extra_read=(entry,),
    )
    log = run / "grade" / f"{mode}.log"
    log.write_text(proc.stdout + proc.stderr, encoding="utf-8")
    if proc.returncode != 0:
        raise RuntimeError(f"Public25 {mode} failed; see {log}")
    return json.loads(proc.stdout.splitlines()[-1])


def audit_episode(path, game_id, contracts, captured, replayed, actions_per_game):
    assert "error" not in captured, "Julia capture failed; see grade/capture.log"
    assert "error" not in replayed, "Julia replay failed; see grade/replay.log"
    assert captured["requested_game_id"] == game_id and not captured["quarantined"]
    commands = [load(row) for row in sorted((path / "commands").glob("*.json"))]
    count = captured["recorded"]
    assert count == actions_per_game + 1, (
        f"Expected RESET and {actions_per_game} concrete actions, recorded {count} events"
    )
    assert [c["kind"] for c in commands] == [
        "open_scorecard",
        "reset",
        *(["action"] * (count - 1)),
        "close_scorecard",
    ], "Incomplete command trace"
    for index, command in enumerate(commands, 1):
        contracts.validate("command", command)
        assert command["sequence"] == index and command["completion"] == "confirmed"
        assert 200 <= command["http_status"] < 300
        assert (
            sha256(command["request_body"].encode()).hexdigest()
            == command["request_sha256"]
        )
        assert (
            digest(path / "blobs" / command["response_blob"])
            == command["response_blob"]
        )

    last_event = None
    previous = None
    trace = []
    report = load(path / "replay.json")
    assert len(report["applied_events"]) == count
    for command, step in zip(commands[1:-1], report["applied_events"], strict=True):
        event = load(path / "events" / f"{command['event_id']}.json")
        contracts.validate("event", event)
        assert event["sequence"] == command["sequence"]
        assert event["before_ref"] == last_event
        assert event["command_ref"] == command["command_id"]
        assert event["request_sha256"] == command["request_sha256"]
        assert event["response_blob"] == command["response_blob"]
        response = load(path / "blobs" / event["response_blob"])
        assert event["version_refs"]["game"] == response["game_id"] == game_id
        action = event["action"]
        action_id = action["id"]
        assert response["action_input"]["id"] == action_id
        if previous is None:
            assert action_id == 0 and command["path"] == "/api/cmd/RESET"
        else:
            assert action_id in previous["available_actions"]
            assert response["guid"] == previous["guid"]
            assert command["path"] == f"/api/cmd/ACTION{action_id}"
        if action_id == 6:
            assert all(
                response["action_input"]["data"][key] == action[key]
                for key in ("x", "y")
            )
        frames = response["frame"]
        assert event["frame_count"] == len(frames)
        assert event["frame_shapes"] == [
            [len(frame), len(frame[0])] for frame in frames
        ]
        assert step["event_id"] == event["event_id"]
        assert step["response_blob"] == event["response_blob"]
        assert step["frame_count"] == len(frames)
        assert len(step["transitions"]) == len(frames) - int(previous is None)
        previous = response
        last_event = event["event_id"]
        trace.append(
            {"action": action, "frame_count": len(frames), "event_id": last_event}
        )
    for key, applied in (("first_pass", count), ("second_pass", 0)):
        assert replayed[key] == {
            "applied": applied,
            "total": count,
            "through_event": last_event,
        }
    assert report["through_event"] == last_event
    return {
        "events": trace,
        "confirmed_actions": count - 1,
        "final_state": previous["state"],
        "levels_completed": previous["levels_completed"],
    }


def main(config, run):
    root = Path.cwd()
    task = read_task(config)
    bundle, ids = task["offline_bundle"], task["game_ids"]
    actions_per_game = task["actions_per_game"]
    public = run / "public"
    catalog = bundle / "offline_public_games_manifest.json"
    games = bundle / "environment_files"
    if not catalog.is_file() or not games.is_dir():
        reason = "missing_official_offline_bundle"
        write_json(public / "summary.json", {"status": "BLOCKED", "reason": reason})
        for game_id in ids:
            append_assertion(run, game_id, None, ["public/summary.json"], reason)
        return 3
    write_json(public / "arc-source.json", source_manifest(catalog, games, ids))
    runtime = runtime_paths(root)
    script = root / "tests/julia/collect_public25.jl"
    entry = root / "scripts/run.jl"
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        run / "private/server",
        run / "grade/environment.log",
    ) as (url, pid):
        with requests.Session() as client:
            client.trust_env = False
            listed = client.get(f"{url}/api/games", timeout=10, allow_redirects=False)
            listed.raise_for_status()
            (public / "http-game-list.json").write_bytes(listed.content)
            assert sorted(item["game_id"] for item in listed.json()) == sorted(ids)
        base, revision = ids[0].split("-")
        checks = isolation_probe(
            root,
            url,
            games / base / revision / f"{base}.py",
            run / "private",
            pid,
            launch=lambda command: solver_sandbox(
                root, runtime, command, public, script=script, extra_read=(entry,)
            ),
        )
        write_json(public / "solver-isolation.json", checks)
        episodes = []
        for game_id in ids:
            path = public / game_id
            path.mkdir()
            write_episode_config(path / "agent.toml", url, game_id, actions_per_game)
            episodes.append({"game_id": game_id, "public": str(path)})
        write_json(public / "episodes.json", episodes)
        captured = run_batch(root, runtime, run, "capture", script, entry)
    replayed = run_batch(root, runtime, run, "replay", script, entry)

    contracts = Contracts(root / "protocol/v1")
    results = {}
    for game_id in ids:
        evidence = [
            f"public/{game_id}",
            "public/arc-source.json",
            "public/http-game-list.json",
            "public/solver-isolation.json",
        ]
        try:
            summary = audit_episode(
                public / game_id,
                game_id,
                contracts,
                captured[game_id],
                replayed[game_id],
                actions_per_game,
            )
        except (
            AssertionError,
            OSError,
            ValueError,
            KeyError,
            ValidationError,
        ) as error:
            reason = (
                f"{type(error).__name__}: {error}"
                if str(error)
                else type(error).__name__
            )
            results[game_id] = {"status": "FAIL", "reason": reason}
            append_assertion(run, game_id, False, evidence, reason)
        else:
            results[game_id] = {"status": "PASS", **summary}
            append_assertion(run, game_id, True, evidence)
    passes = sum(row["status"] == "PASS" for row in results.values())
    write_json(
        public / "summary.json",
        {
            "passed": passes,
            "expected": len(ids),
            "actions_required_per_game": actions_per_game,
            "confirmed_actions": sum(
                row.get("confirmed_actions", 0) for row in results.values()
            ),
            "games": results,
        },
    )
    return int(passes != len(ids))


if __name__ == "__main__":
    sys.exit(main(*(Path(arg) for arg in sys.argv[1:])))
