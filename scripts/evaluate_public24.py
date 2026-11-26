"""Run the cold autonomous controller on the other official local games."""

import argparse
from collections import Counter
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

from tests.bench.check_real_public import offline_capture, public_scorecard_win
from tests.bench.measurement_audit import receipts
from tests.bench.policy_audit import TrajectoryPolicyAudit

ROOT = Path(__file__).resolve().parents[1]


def load(path):
    return json.loads(path.read_bytes())


def frame_identity(response):
    raw = json.dumps(response["frame"], separators=(",", ":")).encode()
    return sha256(raw).hexdigest()


def earlier_start(public):
    first = load(public / "replay.json")["applied_events"][0]
    return frame_identity(load(public / "blobs" / first["response_blob"]))


def require_acceptance(path, checks):
    verdict = load(path)
    observed = {row["id"]: row["status"] for row in verdict["tasks"]}
    if verdict["status"] != "PASS" or any(
        observed.get(check) != "PASS" for check in checks
    ):
        raise ValueError(f"Required qualification missing in {path}: {observed}")
    return load(path.parent / "source-identity.json")["solver_source_sha256"]


def unconfirmed_transport(case):
    public = case / "public"
    for path in (public / "command-failures").glob("*.json"):
        diagnostic = load(path)
        if diagnostic["stage"] == "request":
            receipt = load(public / "commands" / path.name)
            if (
                receipt["completion"] == "outcome_unknown"
                and receipt["reason"] == "transport_or_storage"
                and "http_status" not in receipt
            ):
                return diagnostic
    return None


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
    if (
        code != 0
        and result["budget_commands"] == "unlimited"
        and (failure := unconfirmed_transport(task_dir)) is not None
    ):
        _, last = next(reversed(trace.values()))
        result.update(
            state=last["state"],
            levels=last["levels_completed"],
            transport_failure=failure,
            replay_status="quarantined_before_retry",
        )
        write_json(public / "generalization.json", result)
        write_artifact_index(task_dir)
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
    clicks, object_probes, coordinate_probes = 0, 0, 0
    object_effect_followups = 0
    intervention_goals, intervention_confirmed, intervention_refuted = 0, 0, 0
    relation_results = Counter()
    policy_results = Counter()
    policy_audit = TrajectoryPolicyAudit(public)
    first_obligations = {}
    failures = []
    retries = []
    peak = first["levels_completed"]
    for event, response in ordered:
        if not event["action"]["id"]:
            attempt_file = public / "attempts" / (event["command_ref"] + ".json")
            if attempt_file.is_file():
                attempt = load(attempt_file)
                assert attempt["event"] == event["event_id"]
                assert attempt["level"] == response["levels_completed"]
                if revision := attempt["revision"]:
                    assert trace[revision["event"]][1]["state"] == "GAME_OVER"
                    assert attempt["prior"] == revision["event"] == event["before_ref"]
                    retries.append(attempt)
            continue
        command = event["command_ref"] + ".json"
        check = load(public / "checks" / command)
        decision = load(public / "decisions" / command)
        assert check["action"] == decision["action"] == event["action"]
        parent = trace[event["before_ref"]][1]
        assert event["action"]["id"] in parent["available_actions"]
        peak = max(peak, response["levels_completed"])
        checked += 1
        clicks += event["action"]["id"] == 6
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
        if relation := check.get("public_relation_feedback"):
            assert (
                relation["event"] == event["event_id"]
                and relation["before"] == event["before_ref"]
            )
            assert relation["reached"] == {
                "advanced": response["levels_completed"] > parent["levels_completed"],
                "state": response["state"],
            }
            assert decision["task_arbitration"]["choice"]["action"] == event["action"]
            relation_results["confirmed_transitions"] += 1
            if operation := decision.get("public_relation_task"):
                relation_results[operation["intent"]] += 1
                if operation["reads"]:
                    prediction = load(public / "predictions" / command)
                    assert set(operation["reads"]) <= set(prediction["event_reads"])
                    assert all(
                        trace[ref][0]["sequence"] < event["sequence"]
                        for ref in operation["reads"]
                    )
                assert relation["feedback"]["intent"] == operation["intent"]
                relation_results[relation["feedback"]["result"]] += 1
                if relation["feedback"]["result"] == "refuted":
                    first_obligations.setdefault("task_refuted", event["event_id"])
            if relation["unresolved"]:
                for reason in relation["unresolved"]:
                    first_obligations.setdefault(reason, event["event_id"])
            if failure := relation["failure"]:
                assert failure["history"][-1] == event["event_id"]
                assert response["state"] == "GAME_OVER"
                failures.append(event["event_id"])
                first_obligations.setdefault("public_failure", event["event_id"])
        if policy := check.get("relation_policy_feedback"):
            evidence = decision["relation_policy"]
            assert set(evidence["definitions"]) <= set(check["definition_refs"])
            policy_audit.verify(evidence, policy, event, trace, check["read_events"])
            changed = evidence["baseline_action"] != event["action"]
            assert evidence["changed_action"] == changed
            policy_results["steps"] += 1
            policy_results["changed_baseline_action"] += changed
            policy_results[policy["result"]] += 1
            for branch in [*evidence["branches"], *policy["branches"]]:
                policy_results[
                    f"{branch['control']}_{str(branch['outcome']).lower()}"
                ] += 1
        if withdrawal := decision.get("relation_policy_withdrawal"):
            assert trace[withdrawal["last_observed"]][0]["sequence"] < event["sequence"]
            policy_results["unbound_next_task"] += 1
            first_obligations.setdefault("policy_binding", event["event_id"])
        if feedback := check.get("intervention_feedback"):
            source = decision["intervention"]
            advanced = response["levels_completed"] > parent["levels_completed"]
            assert (
                feedback["event"] == event["event_id"]
                and feedback["advanced"] == advanced
            )
            assert (
                feedback["action"] == event["action"]
                and feedback["before"] == event["before_ref"]
            )
            object_probes += source["probe"] == "representative"
            coordinate_probes += source["probe"] == "coordinate"
            if hypothesis := source.get("hypothesis"):
                assert source["probe"] == "representative" and hypothesis["effects"]
                assert all(
                    trace[ref][0]["sequence"] < event["sequence"]
                    for ref in hypothesis["reads"]
                )
                object_effect_followups += 1
            if goal := source["goal"]:
                predicted = load(public / "predictions" / command)
                assert predicted["predicted_values"]["public_advancement"] is True
                assert set(goal["reads"]) <= set(predicted["event_reads"])
                assert all(
                    trace[ref][0]["sequence"] < event["sequence"]
                    for ref in goal["reads"]
                )
                assert feedback["result"] == ("established" if advanced else "refuted")
                intervention_goals += 1
                intervention_confirmed += advanced
                intervention_refuted += not advanced
        if response["levels_completed"] > parent["levels_completed"]:
            outcomes.append(
                dict(event=event["event_id"], completed=response["levels_completed"])
            )
    win, scorecard_digest = public_scorecard_win(public, game_id, last)
    result.update(
        replay_exit=proc.returncode,
        state=last["state"],
        levels=last["levels_completed"],
        peak_levels=peak,
        target=last["win_levels"],
        actions=checked,
        resets=sum(not row["action_input"]["id"] for _, row in ordered),
        frames=sum(len(row["frame"]) for _, row in ordered),
        cold_start=first["action_input"]["id"] == 0
        and first["levels_completed"] == 0
        and "prior_evidence" not in config["learning"],
        scorecard_win=win,
        scorecard_sha256=scorecard_digest,
        same_session=len({row["guid"] for _, row in ordered}) == 1,
        advancement=outcomes,
        learned_tasks=learned_tasks,
        learned_policies=learned_policies,
        established_tasks=established_tasks,
        policy_stops=policy_stops,
        clicks=clicks,
        object_probes=object_probes,
        coordinate_probes=coordinate_probes,
        object_effect_followups=object_effect_followups,
        intervention_goals=intervention_goals,
        intervention_confirmed=intervention_confirmed,
        intervention_refuted=intervention_refuted,
        reached_ten_actions=checked >= 10,
        actions_with_definitions=defined,
        local_predictions_supported=supported,
        actions_with_residual=residual,
        relation_results=dict(relation_results),
        relation_policy_results=dict(policy_results),
        first_obligations=first_obligations,
        failures=failures,
        retries=retries,
        first_frame_sha256=frame_identity(first),
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


def evaluate_isolated(directory, game, runtime):
    command = private_network(
        [
            runtime["python"]["executable"],
            "-m",
            "scripts.evaluate_public24",
            "--one",
            str(directory),
        ],
        (directory,),
    )
    with (directory / "grade/process.log").open("wb") as log:
        process = subprocess.run(
            command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=False
        )
    report = directory / "public/generalization.json"
    row = load(report) if report.is_file() else {"game_id": game, "verified": False}
    return {**row, "worker_exit": process.returncode}


def comparison_profile(profile):
    normalized = dict(profile)
    normalized["environment"] = {
        k: v for k, v in profile["environment"].items() if k != "game_id"
    }
    normalized["learning"] = {
        k: v
        for k, v in profile["learning"].items()
        if k not in ("engine", "policy_file")
    }
    return normalized


def campaign(args):
    qualifications = (
        {
            "unified_relations": (
                args.unified_relations,
                ("public_relation_feedback_loop",),
            ),
            "relation_policies": (
                args.relation_policies,
                ("public_trajectory_policy",),
            ),
        }
        if args.unified_relations
        else {
            "native": (
                args.native,
                (
                    "autonomous_public_win",
                    "autonomous_goal_program",
                    "autonomous_learned_task",
                    "autonomous_learned_policy",
                ),
            ),
            "relationships": (args.relationships, ("learned_relationship_tasks",)),
            "policy": (args.policy, ("published_policy_withheld_instances",)),
            "projection": (args.projection, ("conditioned_projection_program",)),
        }
    )
    earlier_sources = {
        require_acceptance(path, checks) for path, checks in qualifications.values()
    }
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
    if args.interventions:
        qualifications["interventions"] = (
            args.interventions,
            ("object_intervention_advancement",),
        )
        if (
            require_acceptance(args.interventions, ("object_intervention_advancement",))
            != source
        ):
            raise ValueError(
                "Object interventions must qualify on this campaign source"
            )
    elif earlier_sources != {source}:
        raise ValueError("Both deliveries must qualify on the exact campaign source")
    config_file = ROOT / "config/autonomous_public.toml"
    profile = tomllib.loads(config_file.read_text())
    rust = (config_file.parent / profile["learning"]["engine"]).resolve()
    policy = (config_file.parent / profile["learning"]["policy_file"]).resolve()
    engine = build_identity(ROOT, rust)
    if args.native and (
        load(args.native.parent / "supervision.json")["engine_identity"]["build_sha256"]
        != engine["build_sha256"]
    ):
        raise ValueError("The qualification and campaign engine sources differ")
    baseline = profile["environment"]["game_id"]
    suite = read_task(ROOT / "config/acceptance/arc_public25.toml")
    games = [value for value in suite["game_ids"] if value != baseline]
    if len(set(games)) != len(games) or len(games) != 24:
        raise ValueError("Expected all 24 other official games")
    comparison = None
    comparison_rows = {}
    baseline_starts = {}
    baseline_sources = {}
    if args.baseline:
        prior_manifest = args.baseline / "manifest.json"
        prior_report = args.baseline / "generalization.json"
        earlier = load(prior_manifest)
        observed = load(prior_report)
        if (
            (
                not args.unified_relations
                and earlier_sources != {earlier["solver_source_sha256"]}
            )
            or earlier["games"] != games
            or observed["verified"] != len(games)
            or earlier["engine"]["binary_sha256"] != engine["binary_sha256"]
            or earlier["policy_sha256"] != sha256(policy.read_bytes()).hexdigest()
        ):
            raise ValueError("The rerun must match a completed, qualified baseline")
        for game in games:
            original = tomllib.loads((args.baseline / game / "agent.toml").read_text())
            if comparison_profile(original) != comparison_profile(profile):
                raise ValueError(f"Changed comparison configuration for {game}")
        comparison = dict(
            path=str(args.baseline.resolve()),
            commit=earlier["commit"],
            manifest_sha256=sha256(prior_manifest.read_bytes()).hexdigest(),
            report_sha256=sha256(prior_report.read_bytes()).hexdigest(),
        )
        comparison_rows = {row["game_id"]: row for row in observed["games"]}
        for game in games:
            path = args.baseline / game / "public"
            baseline_starts[game] = earlier_start(path)
            baseline_sources[game] = load(path / "arc-source.json")
    workload = (
        sorted(games, key=lambda game: -comparison_rows[game].get("capture_seconds", 0))
        if comparison_rows
        else games
    )
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
            comparison=comparison,
            policy_sha256=sha256(policy.read_bytes()).hexdigest(),
            qualification={
                key: {
                    "path": str(path.resolve()),
                    "sha256": sha256(path.read_bytes()).hexdigest(),
                }
                for key, (path, _) in qualifications.items()
            },
            games=games,
            dispatch_order=workload,
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

    finished = {}
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        jobs = {
            pool.submit(evaluate_isolated, out / game, game, runtime): game
            for game in workload
        }
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
            pairs = [
                {
                    "game_id": row["game_id"],
                    "before": comparison_rows[row["game_id"]]["levels"],
                    "after": row["levels"],
                    "peak": row["peak_levels"],
                    "same_public_start": row["first_frame_sha256"]
                    == baseline_starts[row["game_id"]],
                    "same_game_build": load(
                        out / row["game_id"] / "public/arc-source.json"
                    )
                    == baseline_sources[row["game_id"]],
                }
                for row in answers
                if row["verified"] and row["game_id"] in comparison_rows
            ]
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
                "peak_levels": sum(
                    row.get("peak_levels", 0) for row in answers if row["verified"]
                ),
                "comparison": pairs,
            }
            write_json(out / "generalization.json", report)
    print(
        json.dumps(
            {
                key: value
                for key, value in report.items()
                if key not in ("games", "comparison")
            }
        ),
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
    parser.add_argument("--interventions", type=Path)
    parser.add_argument("--unified-relations", type=Path)
    parser.add_argument("--relation-policies", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--workers", type=int, default=5)
    args = parser.parse_args()
    if args.one:
        raise SystemExit(int(not evaluate_one(args.one).get("verified", False)))
    modern = args.unified_relations or args.relation_policies
    if modern and (
        not args.unified_relations
        or not args.relation_policies
        or any(
            (
                args.native,
                args.relationships,
                args.policy,
                args.projection,
                args.interventions,
            )
        )
    ):
        parser.error("The two relation acceptances qualify a unified controller")
    if not modern and bool(args.baseline) != bool(args.interventions):
        parser.error(
            "an object-intervention rerun requires both its acceptance and completed baseline"
        )
    if (
        not args.output
        or args.workers < 1
        or (
            not modern
            and not all((args.native, args.relationships, args.policy, args.projection))
        )
    ):
        parser.error(
            "Qualification records, an output directory and a positive worker count are required"
        )
    raise SystemExit(campaign(args))
