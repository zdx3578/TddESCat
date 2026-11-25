"""Run the cold autonomous controller on the other official local games."""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from hashlib import sha256
import json
from pathlib import Path
import re
import subprocess
import tomllib
from time import monotonic

from tddesc_tools.isolation import private_network, solver_sandbox
from tddesc_tools.run import (
    julia_command,
    read_task,
    runtime_paths,
    worktree_digest,
    write_artifact_index,
    write_json,
)
from tddesc_tools.stitch import build_identity

from tests.bench.check_real_public import offline_capture
from tests.bench.measurement_audit import receipts

ROOT = Path(__file__).resolve().parents[1]


def load(path):
    return json.loads(path.read_bytes())


def require_acceptance(path, checks):
    verdict = load(path)
    observed = {row["id"]: row["status"] for row in verdict["tasks"]}
    if verdict["status"] != "PASS" or any(
        observed.get(check) != "PASS" for check in checks
    ):
        raise ValueError(f"Required qualification missing in {path}: {observed}")
    return load(path.parent / "source-identity.json")["solver_source_sha256"]


def evaluate_one(task_dir):
    public = task_dir / "public"
    grade = task_dir / "grade"
    runtime = runtime_paths(ROOT)
    task_file = task_dir / "task.toml"
    task = read_task(task_file)
    config = tomllib.loads(task["agent_config"].read_text())
    game_id = config["environment"]["game_id"]
    started = monotonic()
    code = offline_capture(ROOT, task, task_dir)
    agent_seconds = monotonic() - started
    trace = receipts(public)
    result = {
        "game_id": game_id,
        "capture_exit": code,
        "started": bool(trace),
        "budget_commands": config["execution"]["max_public_commands"],
        "capture_seconds": round(agent_seconds, 3),
    }
    if not trace:
        write_json(public / "generalization.json", result)
        return result
    replay_script = ROOT / "scripts/run.jl"
    with (grade / "replay.log").open("wb") as log:
        proc = subprocess.run(
            solver_sandbox(
                ROOT,
                runtime,
                julia_command(ROOT, runtime, replay_script, "--replay", str(public)),
                public,
                script=replay_script,
                offline=True,
            ),
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    ordered = list(trace.values())
    first, last = ordered[0][1], ordered[-1][1]
    checked, defined, supported, residual = 0, 0, 0, 0
    learned_tasks, learned_policies, outcomes = 0, 0, []
    established_tasks, policy_stops = 0, 0
    for event, response in ordered:
        if not event["action"]["id"]:
            continue
        command = event["command_ref"] + ".json"
        check = load(public / "checks" / command)
        decision = load(public / "decisions" / command)
        assert check["action"] == decision["action"] == event["action"]
        parent = trace[event["before_ref"]][1]
        assert event["action"]["id"] in parent["available_actions"]
        checked += 1
        if check["definition_refs"]:
            defined += 1
        if set(check["assessments"].values()) == {"supported"}:
            supported += 1
        residual += bool(check["evidence"]["residual"])
        learned_tasks += bool(decision.get("relation_task"))
        learned_policies += bool(decision.get("learned_policy"))
        established_tasks += (check.get("task_feedback") or {}).get(
            "outcome"
        ) == "established"
        policy_stops += (check.get("learned_policy_feedback") or {}).get(
            "result"
        ) == "stopped"
        if response["levels_completed"] > parent["levels_completed"]:
            outcomes.append(
                dict(event=event["event_id"], completed=response["levels_completed"])
            )
    close = next(
        (
            command
            for file in sorted((public / "commands").glob("*.json"), reverse=True)
            if (command := load(file))["kind"] == "close_scorecard"
        ),
        {},
    )
    scorecard = (
        load(public / "blobs" / close["response_blob"])
        if close.get("completion") == "confirmed"
        else {}
    )
    win = any(
        entry["id"] == game_id
        and entry["completed"]
        and any(
            row["guid"] == last["guid"] and row["state"] == "WIN"
            for row in entry["runs"]
        )
        for entry in scorecard.get("environments", [])
    )
    result.update(
        replay_exit=proc.returncode,
        state=last["state"],
        levels=last["levels_completed"],
        target=last["win_levels"],
        actions=checked,
        resets=sum(not row["action_input"]["id"] for _, row in ordered),
        frames=sum(len(row["frame"]) for _, row in ordered),
        cold_start=first["action_input"]["id"] == 0
        and first["levels_completed"] == 0
        and "prior_evidence" not in config["learning"],
        scorecard_win=win,
        same_session=len({row["guid"] for _, row in ordered}) == 1,
        advancement=outcomes,
        learned_tasks=learned_tasks,
        learned_policies=learned_policies,
        established_tasks=established_tasks,
        policy_stops=policy_stops,
        reached_ten_actions=checked >= 10,
        actions_with_definitions=defined,
        local_predictions_supported=supported,
        actions_with_residual=residual,
    )
    result["verified"] = (
        code == proc.returncode == 0
        and result["cold_start"]
        and result["same_session"]
        and checked > 0
    )
    if last["state"] == "WIN":
        result["verified"] &= win
    write_json(public / "generalization.json", result)
    write_artifact_index(task_dir)
    return result


def campaign(args):
    qualified_native = require_acceptance(
        args.native,
        (
            "autonomous_public_win",
            "autonomous_goal_program",
            "autonomous_learned_task",
            "autonomous_learned_policy",
        ),
    )
    qualified_relationships = require_acceptance(
        args.relationships, ("learned_relationship_tasks",)
    )
    qualified_policy = require_acceptance(
        args.policy, ("published_policy_withheld_instances",)
    )
    qualified_projection = require_acceptance(
        args.projection, ("conditioned_projection_program",)
    )
    status = subprocess.check_output(
        ["git", "status", "--porcelain"], cwd=ROOT, text=True
    )
    if status:
        raise ValueError("Campaign requires a clean tracked source tree")
    versions = subprocess.check_output(
        ["git", "show", "-s", "--format=%H %T", "HEAD"], cwd=ROOT, text=True
    ).split()
    tree_digest = worktree_digest(ROOT)
    source = worktree_digest(ROOT, sources_only=True)
    if {
        qualified_native,
        qualified_relationships,
        qualified_policy,
        qualified_projection,
    } != {source}:
        raise ValueError("Both deliveries must qualify on the exact campaign source")
    config_file = ROOT / "config/autonomous_public.toml"
    profile = tomllib.loads(config_file.read_text())
    rust = (config_file.parent / profile["learning"]["engine"]).resolve()
    policy = (config_file.parent / profile["learning"]["policy_file"]).resolve()
    native = args.native.parent
    engine = build_identity(ROOT, rust)
    if (
        load(native / "supervision.json")["engine_identity"]["build_sha256"]
        != engine["build_sha256"]
    ):
        raise ValueError("The qualification and campaign engine sources differ")
    baseline = profile["environment"]["game_id"]
    suite = read_task(ROOT / "config/acceptance/arc_public25.toml")
    games = [value for value in suite["game_ids"] if value != baseline]
    if len(set(games)) != len(games) or len(games) != 24:
        raise ValueError("Expected all 24 other official games")
    out = args.output.resolve()
    out.mkdir()
    runtime = runtime_paths(ROOT)
    write_json(
        out / "manifest.json",
        dict(
            commit=versions[0],
            tree=versions[1],
            worktree_sha256=tree_digest,
            solver_source_sha256=source,
            engine=engine,
            policy_sha256=sha256(policy.read_bytes()).hexdigest(),
            qualification={
                key: {
                    "path": str(path.resolve()),
                    "sha256": sha256(path.read_bytes()).hexdigest(),
                }
                for key, path in {
                    "native": args.native,
                    "relationships": args.relationships,
                    "policy": args.policy,
                    "projection": args.projection,
                }.items()
            },
            games=games,
            workers=args.workers,
        ),
    )
    text = config_file.read_text()
    text = re.sub(r"(?m)^engine = .*$", "engine = " + json.dumps(str(rust)), text)
    text = re.sub(
        r"(?m)^policy_file = .*$", "policy_file = " + json.dumps(str(policy)), text
    )
    for game in games:
        d = out / game
        for folder in ("public", "grade"):
            (d / folder).mkdir(parents=True)
        agent = d / "agent.toml"
        agent.write_text(text.replace(f'game_id = "{baseline}"', f'game_id = "{game}"'))
        (d / "task.toml").write_text(
            'schema_version = 1\nkind = "autonomous_offline"\noutput_name = "public-generalization"\n'
            'agent_config = "agent.toml"\n'
            f"environment_config = {json.dumps(str(suite['environment_config']))}\n"
            f"offline_bundle = {json.dumps(str(suite['offline_bundle']))}\n"
        )

    def evaluate(game):
        d = out / game
        cmd = private_network(
            [
                runtime["python"]["executable"],
                "-m",
                "scripts.evaluate_public24",
                "--one",
                str(d),
            ],
            (d,),
        )
        with (d / "grade/process.log").open("wb") as log:
            proc = subprocess.run(
                cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=False
            )
        result = d / "public/generalization.json"
        row = load(result) if result.is_file() else {"game_id": game, "verified": False}
        return {**row, "worker_exit": proc.returncode}

    finished = {}
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        jobs = {pool.submit(evaluate, game): game for game in games}
        for job in as_completed(jobs):
            game = jobs[job]
            try:
                finished[game] = job.result()
            except Exception as error:
                finished[game] = {
                    "game_id": game,
                    "verified": False,
                    "error": str(error),
                }
            answers = [finished[game] for game in games if game in finished]
            report = {
                "games": answers,
                "observed": len(answers),
                "verified": sum(row["verified"] for row in answers),
                "wins": sum(
                    bool(row.get("scorecard_win")) and row["verified"]
                    for row in answers
                ),
                "levels": sum(
                    row.get("levels", 0) for row in answers if row["verified"]
                ),
            }
            write_json(out / "generalization.json", report)
    print(
        json.dumps({key: value for key, value in report.items() if key != "games"}),
        flush=True,
    )
    return int(report["verified"] != len(games))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--one", type=Path)
    parser.add_argument("--native", type=Path)
    parser.add_argument("--relationships", type=Path)
    parser.add_argument("--policy", type=Path)
    parser.add_argument("--projection", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--workers", type=int, default=5)
    args = parser.parse_args()
    if args.one:
        raise SystemExit(int(not evaluate_one(args.one).get("verified", False)))
    if (
        not all(
            (args.native, args.relationships, args.policy, args.projection, args.output)
        )
        or args.workers < 1
    ):
        parser.error(
            "the four acceptance records, output directory and positive worker count are required"
        )
    raise SystemExit(campaign(args))
