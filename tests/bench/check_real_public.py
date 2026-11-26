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

from tests.bench.autonomous_audit import (
    OBSERVED_CONTACT_DOMAIN,
    SiteDomain,
    audit_contact_plan,
    audit_contact_sample,
    audit_progress_plan,
    audit_progress_sample,
    require,
)
from tests.bench.program_audit import audit_live_goal_programs
from tests.bench.policy_audit import PolicyAudit


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
        config.get("planning", {}).get("autonomous") is True
        and "goal" not in config["planning"]
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
    contact_samples = {}
    contact_control = []
    audited_actions = []
    relation_tasks = []
    policy_audit = PolicyAudit(public)
    bootstrap_actions = []
    audit_errors = []
    parents = {}
    site_domain = SiteDomain()
    domain_by_receipt = {}
    survey_cache = {}
    for event in ordered:
        ref = event["event_id"]
        receipt = json.loads((public / "blobs" / event["response_blob"]).read_bytes())
        descriptor = json.loads((public / "events" / f"{ref}.json").read_bytes())
        command = descriptor["command_ref"]
        position = receipt["levels_completed"]
        before = through_level
        parents[ref] = descriptor["before_ref"]
        if receipt["action_input"]["id"] != 0:
            try:
                before_receipt = receipts[parents[ref]]
                check = json.loads((public / "checks" / f"{command}.json").read_bytes())
                decision = json.loads(
                    (public / "decisions" / f"{command}.json").read_bytes()
                )
                if not audited_actions and "site_transitions" in check:
                    site_domain = SiteDomain(OBSERVED_CONTACT_DOMAIN)
                site_domain.observe(
                    decision["site_surveys"], receipts, before, frame_cache=survey_cache
                )
                domain_by_receipt[parents[ref]] = (
                    site_domain.remaining(),
                    site_domain.reads(),
                )
                prediction = json.loads(
                    (public / "predictions" / f"{command}.json").read_bytes()
                )
                require(
                    check["event_ref"] == ref
                    and decision["before_ref"] == parents[ref]
                    and descriptor["action"]
                    == prediction["action"]
                    == decision["action"]
                    == check["action"]
                    and descriptor["action"]["id"] == receipt["action_input"]["id"]
                    and descriptor["action"]["id"]
                    in before_receipt["available_actions"],
                    "action_witness",
                )
                experiment = prediction.get("spatial_experiment")
                reads = set(check["read_events"])
                require(
                    reads <= receipts.keys() and parents[ref] in reads,
                    "action_read_scope",
                )
                require(
                    experiment == decision.get("spatial_experiment"), "frozen_selection"
                )
                trained = []
                if experiment:
                    sources = set(experiment["reads"])
                    require(sources <= reads, "unrecorded_spatial_reads")
                    require(
                        experiment["id"] == decision["action"]["id"],
                        "substituted_action",
                    )
                    trained = sorted(
                        read
                        for read in sources
                        if receipts[read]["action_input"]["id"] != 0
                    )
                    require(trained, "empty_spatial_training")
                    decisions.append(
                        {"event": ref, "level": before + 1, "reads": trained}
                    )
                    if plan := experiment.get("contact"):
                        require(
                            plan["point"] == experiment["frontier"],
                            "control_frontier",
                        )
                        executing = experiment["executes_contact"]
                        if executing:
                            require(
                                plan["point"] == experiment["destination"],
                                "control_landing",
                            )
                        judgment, contrasted = audit_contact_plan(
                            plan,
                            contact_samples,
                            reads,
                            receipts,
                            executing=executing,
                            before=before_receipt,
                        )
                        domain, domain_reads = domain_by_receipt[plan["selected_at"]]
                        progress_judgment = audit_progress_plan(
                            plan,
                            contact_samples,
                            reads,
                            receipts,
                            executing=executing,
                            before=before_receipt,
                            action=decision["action"]["id"],
                            domain=domain,
                            domain_reads=domain_reads,
                            domain_version=site_domain.version,
                        )
                        if executing:
                            reported = check.get("contact_feedback")
                            if reported:
                                require(
                                    reported["point"] == plan["point"]
                                    and reported["site"] == plan["site"]
                                    and reported["context"] == plan["context"]
                                    and reported["facts"] == plan["progress"]["facts"],
                                    "substituted_contact",
                                )
                            contact_control.append(
                                {
                                    "event": ref,
                                    "level": before + 1,
                                    "judgment": judgment,
                                    "progress_judgment": progress_judgment,
                                    "progress_model": plan["progress"]["model"],
                                    "progress_training": plan["progress"][
                                        "sample_events"
                                    ],
                                    "contrasted": contrasted,
                                    "training": plan["conditions"]["sample_events"],
                                    "outcome": (
                                        check.get("contact_feedback") or {}
                                    ).get("outcome"),
                                }
                            )
                elif not decisions and decision["reason"] == "uncovered":
                    bootstrap_actions.append(ref)
                else:
                    require(
                        check["definition_refs"] and prediction["model_version"],
                        "unaccounted_action_selection",
                    )
                    if (check.get("program") or {}).get("goal", {}).get(
                        "contract"
                    ) == "establishes_contact_precondition":
                        trained = sorted(
                            read
                            for read in prediction["event_reads"]
                            if receipts[read]["action_input"]["id"] != 0
                        )
                        require(trained, "missing_contact_producer_training")
                        decisions.append(
                            {"event": ref, "level": before + 1, "reads": trained}
                        )
                if sample := check.get("contact_feedback"):
                    audit_contact_sample(
                        sample, ref, before_receipt, receipt, receipts, parents
                    )
                    audit_progress_sample(
                        sample,
                        before_receipt,
                        receipt,
                        receipts,
                        site_domain=site_domain,
                    )
                    contact_samples[ref] = sample
                    site_domain.entered(sample)
                if task := decision.get("relation_task"):
                    goal, producer, feedback = (
                        task["goal"],
                        task["producer"],
                        check["task_feedback"],
                    )
                    plan = experiment["contact"]
                    require(
                        goal["before"] == parents[ref]
                        and goal["scope"] == site_domain.version
                        and goal["model"] == plan["progress"]["model"]
                        and goal["rules"] == plan["progress"]["rules"]
                        and plan["progress"]["judgment"] == "progress"
                        and producer["target"] == plan["point"]
                        and producer["guard"] == plan["conditions"]["rules"]
                        and producer["advancement"] == goal["rules"]
                        and set(goal["examples"]) <= receipts.keys()
                        and (set(goal["reads"]) | set(producer["read_events"]))
                        <= set(task["reads"])
                        <= reads
                        and feedback["event"] == ref
                        and feedback["observed"]["advanced"] == (position > before)
                        and task["recheck"] == experiment["executes_contact"],
                        "unproved_relation_task",
                    )
                    if feedback["outcome"] == "established":
                        require(
                            task["recheck"]
                            and sample
                            and sample["action"] == producer["action"]
                            and sample["outcome"] == "progress"
                            and position > before,
                            "unproved_task_goal",
                        )
                    relation_tasks.append(
                        dict(
                            event=ref,
                            level=before + 1,
                            model=goal["model"],
                            relation=goal["relation"],
                            producer=producer,
                            requirements=task["requirements"],
                            outcome=feedback["outcome"],
                        )
                    )
                policy_audit.verify(
                    decision.get("learned_policy"),
                    check.get("learned_policy_feedback"),
                    ref,
                    before_receipt,
                    receipt,
                    receipts,
                    site_domain.remaining(),
                    reads,
                )
                if (
                    check["definition_refs"]
                    and check["assessments"]
                    and set(check["assessments"].values()) == {"supported"}
                ):
                    structural_consumption.append(
                        {"event": ref, "definitions": check["definition_refs"]}
                    )
                audited_actions.append(ref)
                if position != before:
                    site_domain.reset_level()
                    policy_audit.refuted.clear()
                elif site_domain.version == OBSERVED_CONTACT_DOMAIN:
                    site_domain.verify_site_transitions(
                        ref, receipt, check["site_transitions"]
                    )
                site_domain.observe(
                    check["site_surveys"],
                    {**receipts, ref: receipt},
                    position,
                    frame_cache=survey_cache,
                )
            except (OSError, KeyError, TypeError, ValueError) as error:
                audit_errors.append({"event": ref, "error": str(error)})
        else:
            site_domain.reset_attempt()
            policy_audit.pending = None
        if position != before:
            progress.append(
                {"completed": position, "event": ref, "sha256": event["response_blob"]}
            )
            through_level = position
        receipts[ref] = receipt
        domain_by_receipt[ref] = (site_domain.remaining(), site_domain.reads())
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
    isolation = json.loads((public / "solver-isolation.json").read_bytes())
    isolated = bool(isolation) and all(isolation.values())
    learned_progress = {}
    for row in contact_control:
        if (
            row["progress_model"]
            and row["progress_judgment"] == row["outcome"] == "progress"
        ):
            learned_progress.setdefault(row["progress_model"], set()).add(row["level"])
    progress_transfer = any(len(levels) > 1 for levels in learned_progress.values())
    passed = (
        cold
        and isolated
        and single_session
        and target > 0
        and not audit_errors
        and progress_transfer
        and {row["event"] for row in progress}
        == {row["event"] for row in contact_control if row["outcome"] == "progress"}
        and all(
            contact_samples.get(row["event"], {}).get("outcome") == "progress"
            for row in progress
        )
        and any(
            row["contrasted"]
            and row["judgment"] == "admitted"
            and row["outcome"] == "progress"
            for row in contact_control
        )
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
        "audited_actions": len(audited_actions),
        "bootstrap_actions": bootstrap_actions,
        "relation_tasks": relation_tasks,
        "learned_policy_uses": policy_audit.uses,
        "audit_errors": audit_errors,
        "contact_samples": list(contact_samples.values()),
        "contact_control": contact_control,
        "progress_transfer": progress_transfer,
        "isolated": isolated,
        "structural_consumption": structural_consumption,
        "scorecard_sha256": close.get("response_blob"),
        "scorecard_win": official_completion,
        "replay_exit": replay.returncode,
    }


def verify_autonomous_capture(root, run, code):
    public = run / "public"
    identifier = "autonomous_public_win"
    report = autonomous_report(root, run)
    report["solver_exit"] = code
    passed = code == 0 and report["passed"]
    report["passed"] = passed
    append_assertion(
        run,
        identifier,
        passed,
        ["public/autonomous-verification.json", "grade/autonomous-replay.log"],
        None if passed else "missing_cold_learning_and_full_game_win",
    )
    agent = tomllib.loads((public / "agent.toml").read_text())
    if agent.get("planning", {}).get("relation_goals", False):
        tasks = report.get("relation_tasks", [])
        achieved = [row for row in tasks if row["outcome"] == "established"]
        solved = any(
            any(
                earlier["level"] == complete["level"]
                and earlier["model"] == complete["model"]
                and earlier["producer"]["target"] == complete["producer"]["target"]
                and earlier["outcome"] == "continue"
                and any(value == "missing" for _, value in earlier["requirements"])
                for earlier in tasks[: tasks.index(complete)]
            )
            for complete in achieved
        )
        learned_task = solved and not report.get("audit_errors")
        append_assertion(
            run,
            "autonomous_learned_task",
            learned_task,
            ["public/autonomous-verification.json"],
            None if learned_task else "missing_learned_goal_and_precondition_chain",
        )
        passed &= learned_task
    if agent["learning"].get("sequences", False):
        program = audit_live_goal_programs(public)
        report["program_control"] = program
        goal_program = (
            bool(program["uses"])
            and program["ordinary_choice_changed"]
            and program["cross_level"]
            and not program["errors"]
        )
        append_assertion(
            run,
            "autonomous_goal_program",
            goal_program,
            ["public/autonomous-verification.json"],
            None
            if goal_program
            else "missing_verified_in_session_program_choice_and_transfer",
        )
        passed &= goal_program
        if agent.get("planning", {}).get("relation_goals", False):
            policy_ok = any(
                row["status"] == "stopped"
                for row in report.get("learned_policy_uses", [])
            ) and not report.get("audit_errors")
            append_assertion(
                run,
                "autonomous_learned_policy",
                policy_ok,
                ["public/autonomous-verification.json"],
                None if policy_ok else "missing_published_policy_actually_consumed",
            )
            passed &= policy_ok
    report["passed"] = passed
    write_json(public / "autonomous-verification.json", report)
    return int(not passed)


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
        return verify_autonomous_capture(root, run, code)
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
