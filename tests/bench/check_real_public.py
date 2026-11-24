"""Validate the published real-interface learning chain."""

import json
import re
import subprocess
import sys
import tomllib
from hashlib import sha256
from importlib.metadata import version
from pathlib import Path

from tddesc_tools.isolation import environment_server, isolation_probe, solver_sandbox
from tddesc_tools.public_run import (
    SUPERVISOR_BLOCKED,
    public_settings,
    solver_command,
    supervise,
)
from tddesc_tools.run import (
    append_assertion,
    julia_command,
    read_task,
    runtime_paths,
    write_json,
)


def offline_capture(root, task, run):
    public = run / "public"
    private = run / "private"
    bundle = task["offline_bundle"]
    catalog = bundle / "offline_public_games_manifest.json"
    games = bundle / "environment_files"
    if not catalog.is_file() or not games.is_dir():
        write_json(
            public / "supervision.json",
            {"state": "BLOCKED", "reason": "missing_official_offline_bundle"},
        )
        return SUPERVISOR_BLOCKED
    runtime = runtime_paths(root)
    original = task["agent_config"]
    text = original.read_text(encoding="utf-8")
    values = tomllib.loads(text)
    game = values["environment"]["game_id"]
    base, revision = game.split("-", 1)
    if not re.fullmatch(r"[a-z0-9]{4}", base) or not re.fullmatch(
        r"[a-f0-9]{8}", revision
    ):
        raise ValueError("Expected a versioned official game id")
    game_dir = games / base / revision
    metadata = game_dir / "metadata.json"
    game_file = game_dir / (base + ".py")
    assert json.loads(metadata.read_bytes())["game_id"] == game
    write_json(
        public / "arc-source.json",
        {
            "environment": "official_offline_http",
            "game_id": game,
            "game_source_sha256": sha256(game_file.read_bytes()).hexdigest(),
            "metadata_sha256": sha256(metadata.read_bytes()).hexdigest(),
            "catalog_sha256": sha256(catalog.read_bytes()).hexdigest(),
            "toolkit": version("arc-agi"),
            "engine": version("arcengine"),
        },
    )
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        private / "server",
        run / "grade/environment.log",
    ) as (url, server_pid):
        agent = public / "agent.toml"
        engine = (original.parent / values["learning"]["engine"]).resolve()
        projection = re.sub(
            r"(?m)^base_url\s*=.*$", f"base_url = {json.dumps(url)}", text
        )
        projection = re.sub(
            r"(?m)^engine\s*=.*$", f"engine = {json.dumps(str(engine))}", projection
        )
        policy = (original.parent / values["learning"]["policy_file"]).resolve()
        projection = re.sub(
            r"(?m)^policy_file\s*=.*$",
            f"policy_file = {json.dumps(str(policy))}",
            projection,
        )
        agent.write_text(projection, encoding="utf-8")
        paths = public_settings(root, agent, tomllib.loads(projection))
        probe = isolation_probe(
            root,
            url,
            game_file,
            private,
            server_pid,
            launch=lambda command: solver_command(
                root, runtime, agent, public, paths, command=command
            ),
        )
        write_json(public / "solver-isolation.json", probe)
        return supervise(root, agent, public, expected_paths=paths)


def autonomous_report(root, run):
    public = run / "public"
    config = tomllib.loads((public / "agent.toml").read_text(encoding="utf-8"))
    cold = (
        config.get("planning") == {"autonomous": True}
        and "prior_evidence" not in config.get("learning", {})
        and not config["execution"].get("frozen_evaluation", False)
        and not (public / "prior-events.json").exists()
    )
    runtime = runtime_paths(root)
    script = root / "scripts/run.jl"
    with (run / "grade/autonomous-replay.log").open("wb") as log:
        replay = subprocess.run(
            solver_sandbox(
                root,
                runtime,
                julia_command(root, runtime, script, "--replay", str(public)),
                public,
                script=script,
                offline=True,
            ),
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    if replay.returncode:
        return {"passed": False, "cold_start": cold, "replay_exit": replay.returncode}
    ledger = json.loads((public / "replay.json").read_bytes())
    ordered = ledger["applied_events"]
    game_id = config["environment"]["game_id"]
    receipts = {}
    through_level = 0
    progress = []
    decisions = []
    structural_consumption = []
    for event in ordered:
        ref = event["event_id"]
        receipt = json.loads((public / "blobs" / event["response_blob"]).read_bytes())
        descriptor = json.loads((public / "events" / f"{ref}.json").read_bytes())
        command = descriptor["command_ref"]
        position = receipt["levels_completed"]
        before = through_level
        check_path = public / "checks" / f"{command}.json"
        if check_path.is_file():
            check = json.loads(check_path.read_bytes())
            prediction = json.loads(
                (public / "predictions" / f"{command}.json").read_bytes()
            )
            experiment = prediction.get("spatial_experiment", {})
            sources = experiment.get("reads", [])
            trained = [
                read
                for read in sources
                if read in receipts and receipts[read]["action_input"]["id"] != 0
            ]
            if (
                trained
                and set(sources) <= receipts.keys()
                and experiment.get("reason") == "visual_goal_hypothesis"
                and (
                    position > before
                    or (check.get("visual_feedback") or {}).get("verdict")
                    == "supported"
                )
            ):
                decisions.append({"event": ref, "level": before + 1, "reads": trained})
            if (
                check["definition_refs"]
                and check["assessments"]
                and set(check["assessments"].values()) == {"supported"}
            ):
                structural_consumption.append(
                    {"event": ref, "definitions": check["definition_refs"]}
                )
        if position != before:
            progress.append(
                {"completed": position, "event": ref, "sha256": event["response_blob"]}
            )
            through_level = position
        receipts[ref] = receipt
    final = receipts.get(ledger["through_event"], {})
    target = final.get("win_levels", 0)
    first = next(iter(receipts.values()), {})
    cold &= (
        first.get("action_input", {}).get("id") == 0
        and first.get("levels_completed") == 0
        and {row["win_levels"] for row in receipts.values()} == {target}
    )
    commands = sorted((public / "commands").glob("*.json"))
    close = json.loads(commands[-1].read_bytes()) if commands else {}
    scorecard = (
        json.loads((public / "blobs" / close["response_blob"]).read_bytes())
        if close.get("kind") == "close_scorecard"
        and close.get("completion") == "confirmed"
        else {}
    )
    official_completion = any(
        game["id"] == game_id
        and game["completed"]
        and any(
            trace["guid"] == final.get("guid") and trace["state"] == "WIN"
            for trace in game["runs"]
        )
        for game in scorecard.get("environments", [])
    )
    single_session = {(row["game_id"], row["guid"]) for row in receipts.values()} == {
        (game_id, final.get("guid"))
    }
    passed = (
        cold
        and single_session
        and target > 0
        and [row["completed"] for row in progress] == list(range(1, target + 1))
        and final.get("state") == "WIN"
        and official_completion
        and {row["level"] for row in decisions} == set(range(1, target + 1))
    )
    return {
        "passed": passed,
        "cold_start": cold,
        "single_session": single_session,
        "state": final.get("state"),
        "progress": progress,
        "levels_completed": through_level,
        "win_levels": target,
        "events": len(ordered),
        "frames": sum(row["frame_count"] for row in ordered),
        "learned_decisions": decisions,
        "structural_consumption": structural_consumption,
        "scorecard_sha256": close.get("response_blob"),
        "scorecard_win": official_completion,
        "replay_exit": replay.returncode,
    }


def main(config, run):
    root = Path.cwd()
    task = read_task(config)
    public = run / "public"
    autonomous = task["kind"] == "autonomous_offline"
    offline = task["kind"] == "arc_offline" or autonomous
    code = (
        offline_capture(root, task, run)
        if offline
        else supervise(root, task["agent_config"], public)
    )
    status = json.loads((public / "supervision.json").read_bytes())
    identifier = "autonomous_public_win" if autonomous else "public_learning_loop"
    if code == SUPERVISOR_BLOCKED:
        append_assertion(
            run, identifier, None, ["public/supervision.json"], status["reason"]
        )
        return code
    if autonomous and (public / "agent.toml").is_file():
        report = autonomous_report(root, run)
        report["solver_exit"] = code
        passed = code == 0 and report["passed"]
        report["passed"] = passed
        write_json(public / "autonomous-verification.json", report)
        append_assertion(
            run,
            identifier,
            passed,
            ["public/autonomous-verification.json", "grade/autonomous-replay.log"],
            None if passed else "missing_cold_learning_and_full_game_win",
        )
        return int(not passed)
    if code:
        append_assertion(
            run,
            identifier,
            False,
            ["public/supervision.json"],
            f"public_capture_exit:{code}",
        )
        return 1
    events = {
        row["event_id"]: row
        for path in (public / "events").glob("*.json")
        if (row := json.loads(path.read_bytes()))["completion"] == "confirmed"
    }
    checks = [
        json.loads(path.read_bytes()) for path in (public / "checks").glob("*.json")
    ]
    publications = json.loads((public / "public-run.json").read_bytes())["learned"][
        "publications"
    ]
    for digest in publications:
        path = public / "publication" / f"{digest}.json"
        artifact = json.loads(path.read_bytes())
        definitions = set(artifact["new_definition_ids"])
        sources = {o["event_ref"] for o in artifact["origins"]}
        if not definitions or not sources or not sources <= events.keys():
            continue
        last_source = max(events[ref]["sequence"] for ref in sources)
        for checked in sorted(
            checks, key=lambda row: events[row["event_ref"]]["sequence"]
        ):
            support = checked["assessments"]
            used = definitions.intersection(checked["definition_refs"])
            if (
                last_source < events[checked["event_ref"]]["sequence"]
                and used
                and support
                and set(support.values()) == {"supported"}
            ):
                consumed = events[checked["event_ref"]]
                command = json.loads(
                    (
                        public / "commands" / (consumed["command_ref"] + ".json")
                    ).read_bytes()
                )
                prediction = (
                    public / "predictions" / (command["prediction_ref"] + ".json")
                )
                assert prediction.is_file() and command["completion"] == "confirmed"
                assert (
                    sha256(
                        (public / "blobs" / consumed["response_blob"]).read_bytes()
                    ).hexdigest()
                    == consumed["response_blob"]
                )
                audited = {
                    occ
                    for call in artifact["calls"]
                    if call["definition_ref"] in used
                    for occ in call["source_occurrences"]
                }
                used_sources = {
                    row["event_ref"]
                    for row in artifact["origins"]
                    if row["occurrence_id"] in audited
                }
                assert used_sources and used_sources <= sources
                summary = {
                    "definition_refs": sorted(used),
                    "source_events": sorted(used_sources),
                    "consumption_event": checked["event_ref"],
                    "command_ref": command["command_id"],
                    "action": checked["action"],
                    "confirmed_response_sha256": consumed["response_blob"],
                    "assessments": support,
                    "publication": digest,
                    "recorded_events": len(events),
                    "supported_predictions": sum(
                        bool(row["assessments"])
                        and set(row["assessments"].values()) == {"supported"}
                        for row in checks
                    ),
                    "refuted_predictions": sum(
                        "refuted" in row["assessments"].values() for row in checks
                    ),
                }
                write_json(public / "verified-chain.json", summary)
                append_assertion(
                    run,
                    identifier,
                    True,
                    [
                        "public/verified-chain.json",
                        path.relative_to(run).as_posix(),
                        prediction.relative_to(run).as_posix(),
                        *(
                            ["public/arc-source.json", "public/solver-isolation.json"]
                            if offline
                            else []
                        ),
                    ],
                )
                return 0
    append_assertion(
        run,
        identifier,
        False,
        ["public/public-run.json"],
        "no_real_discovery_to_confirmed_consumption_chain",
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
