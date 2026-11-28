"""Evaluate the cold controller on all 25 versioned public games until completion."""

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from hashlib import file_digest
import json
from pathlib import Path
import re
import shutil
import subprocess
from time import monotonic
import tomllib

from tddesc_tools.public_run import absolute_compute_settings, atomic_json
from tddesc_tools.run import (
    julia_command,
    julia_environment,
    read_task,
    runtime_paths,
    worktree_digest,
)
from tddesc_tools.stitch import build_identity

from scripts.evaluate_public24 import ROOT, evaluate_isolated, unconfirmed_transport


def prepare_cases(output, games, template, suite, bundle):
    settings = template.read_text(encoding="utf-8")
    data = tomllib.loads(settings)
    assert data["execution"]["max_public_commands"] == "unlimited"
    assert data["planning"]["autonomous"] is True
    assert data["environment"]["game_selection"] == "explicit"
    assert data["environment"]["competition_mode"] is False
    assert "prior_evidence" not in data["learning"]
    engine_path = (template.parent / data["learning"]["engine"]).resolve()
    policy_path = (template.parent / data["learning"]["policy_file"]).resolve()

    settings = absolute_compute_settings(template, data, settings)
    settings = re.sub(
        r"(?m)^engine = .*$", f"engine = {json.dumps(str(engine_path))}", settings
    )
    settings = re.sub(
        r"(?m)^policy_file = .*$",
        f"policy_file = {json.dumps(str(policy_path))}",
        settings,
    )
    for game in games:
        case = output / game
        for folder in ("public", "grade"):
            (case / folder).mkdir(parents=True)
        (case / "agent.toml").write_text(
            re.sub(r"(?m)^game_id = .*$", f'game_id = "{game}"', settings),
            encoding="utf-8",
        )
        (case / "task.toml").write_text(
            'schema_version = 1\nkind = "autonomous_offline"\n'
            'output_name = "v13-public25"\nagent_config = "agent.toml"\n'
            f"environment_config = {json.dumps(str(suite['environment_config']))}\n"
            f"offline_bundle = {json.dumps(str(bundle))}\n",
            encoding="utf-8",
        )
    return engine_path, policy_path


def game_verdict(row):
    verified = row.get("verified") is True and row.get("worker_exit") == 0
    if verified and row.get("state") == "WIN" and row.get("scorecard_win") is True:
        return "WIN"
    if verified:
        return "NOT_WON"
    return "UNVERIFIED" if row.get("started") else "BLOCKED"


def backend_receipts(public):
    counts = Counter()
    for path in (public / "learning").glob("job-*/worker-status.json"):
        status = json.loads(path.read_bytes())
        counts["stitch_jobs"] += 1
        if status["failure"] or status["code"] not in (0, 10, 22):
            counts["stitch_errors"] += 1
        elif status["code"] == 0:
            counts["stitch_completed"] += 1
        else:
            counts["stitch_partial"] += 1
    for path in (public / "learning/circuits").glob("*.json"):
        artifact = json.loads(path.read_bytes())
        counts["circuit_candidates"] += 1
        counts["circuit_calibrated"] += (
            artifact["applicable"] and artifact["calibration"]["accepted"]
        )
        counts["history_candidates"] += artifact.get("history") is not None
    for path in (public / "learning/histories").glob("*.json"):
        artifact = json.loads(path.read_bytes())
        counts["history_candidates"] += artifact["model"] is not None
        counts["history_published"] += artifact["applicable"] is True
    for path in (public / "decisions").glob("*.json"):
        decision = json.loads(path.read_bytes())
        if proof := decision.get("factor_role_proof"):
            counts["factor_binding_proofs"] += (
                proof["execution"] == "completed"
                and (proof["value"] or {}).get("entailed") is True
            )
        task = decision.get("public_relation_task") or {}
        obligation = task.get("obligation") or {}
        counts["statistical_dispatch_changes"] += (
            isinstance(obligation, dict) and obligation.get("circuit") is not None
        )
        history = obligation.get("history") if isinstance(obligation, dict) else None
        # Concrete experiments also quote their observed action prefix under "history".
        if isinstance(history, dict) and isinstance(history.get("changed_action"), bool):
            counts["history_dispatches"] += 1
            counts["history_dispatch_changes"] += history["changed_action"]
    return dict(counts)


def campaign_report(games, finished):
    rows = [
        finished.get(game, {"game_id": game, "verdict": "PENDING"}) for game in games
    ]
    won = sum(row["verdict"] == "WIN" for row in rows)
    compute = Counter()
    for row in rows:
        compute.update(row.get("compute_receipts", {}))
    return {
        "status": "PASS"
        if won == len(games)
        else ("FAIL" if len(finished) == len(games) else "IN_PROGRESS"),
        "required_wins": len(games),
        "wins": won,
        "finished": len(finished),
        "peak_levels": sum(
            row.get("peak_levels", 0) for row in rows if row.get("verified")
        ),
        "compute_receipts": dict(compute),
        "games": rows,
    }


def sha256_file(path):
    with path.open("rb") as stream:
        return file_digest(stream, "sha256").hexdigest()


def verify_compute_profile(template, runtime):
    command = julia_command(
        ROOT, runtime, ROOT / "scripts/run.jl", "--check-compute", str(template)
    )
    capabilities = json.loads(
        subprocess.check_output(command, cwd=ROOT, env=julia_environment(runtime))
    )
    settings = tomllib.loads(template.read_text(encoding="utf-8"))
    factor = (template.parent / settings["compute"]["factor_kernel"]).resolve()
    return {
        "capabilities": capabilities,
        "factor_kernel_sha256": sha256_file(factor),
        "compute_lock_sha256": sha256_file(ROOT / "python/compute/uv.lock"),
    }


def prepare_online_runtime(runtime):
    command = julia_command(ROOT, runtime, ROOT / "scripts/prepare_online.jl")
    started = monotonic()
    metadata = json.loads(
        subprocess.check_output(command, cwd=ROOT, env=julia_environment(runtime))
    )
    return {**metadata, "prepare_seconds": monotonic() - started}


def evaluate_game(case, game, runtime):
    result = evaluate_isolated(case, game, runtime)
    failure = None if result.get("verified") else unconfirmed_transport(case)
    if failure is None:
        return {**result, "compute_receipts": backend_receipts(case / "public")}
    first = {**result, "verdict": game_verdict(result), "transport_failure": failure}
    first["compute_receipts"] = backend_receipts(case / "public")
    # The previous GUID stays quarantined. Start a cold case and retain both
    # sets of public transactions independently.
    retry = case / "transport-retry"
    for directory in ("public", "grade"):
        (retry / directory).mkdir(parents=True)
    for name in ("agent.toml", "task.toml"):
        shutil.copyfile(case / name, retry / name)
    result = evaluate_isolated(retry, game, runtime)
    return {
        **result,
        "selected_attempt": retry.name,
        "discarded_transport_attempt": first,
        "compute_receipts": backend_receipts(retry / "public"),
    }


def campaign(args):
    runtime = runtime_paths(ROOT)
    catalog_config = ROOT / "config/acceptance/arc_public25.toml"
    suite = read_task(catalog_config)
    games = tuple(suite["game_ids"])
    bundle = (args.bundle or suite["offline_bundle"]).resolve()
    catalog = bundle / "offline_public_games_manifest.json"
    if not catalog.is_file() or not (bundle / "environment_files").is_dir():
        raise ValueError(f"Official offline bundle missing: {bundle}")
    if not 1 <= args.workers <= len(games):
        raise ValueError("workers must be between 1 and 25")

    output = args.output.resolve()
    template = ROOT / "config/v13_public25.toml"
    online_runtime = (
        prepare_online_runtime(runtime)
        if getattr(args, "precompile_online", False)
        else None
    )
    compute = verify_compute_profile(template, runtime)
    output.mkdir(parents=True)
    engine, policy = prepare_cases(output, games, template, suite, bundle)
    commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()
    atomic_json(
        output / "manifest.json",
        {
            "schema_version": 1,
            "commit": commit,
            "worktree_sha256": worktree_digest(ROOT),
            "solver_source_sha256": worktree_digest(ROOT, sources_only=True),
            "engine": build_identity(ROOT, engine),
            "compute": compute,
            "online_runtime": online_runtime,
            "policy_sha256": sha256_file(policy),
            "profile_sha256": sha256_file(template),
            "catalog_sha256": sha256_file(catalog),
            "game_ids": games,
            "command_budget": "unlimited",
            "workers": args.workers,
        },
    )
    report_file = output / "public25.json"
    finished = {}
    atomic_json(report_file, campaign_report(games, finished))
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        tasks = {
            pool.submit(evaluate_game, output / game, game, runtime): game
            for game in games
        }
        for task in as_completed(tasks):
            game = tasks[task]
            try:
                row = task.result()
            except Exception as error:
                row = {"game_id": game, "error": str(error)}
            row["verdict"] = game_verdict(row)
            finished[game] = row
            report = campaign_report(games, finished)
            atomic_json(report_file, report)
            print(
                f"{game} {row['verdict']} "
                f"({report['wins']}/{len(games)} WIN, {report['finished']} finished)",
                flush=True,
            )
    return 0 if report["status"] == "PASS" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--workers", type=int, default=25)
    parser.add_argument(
        "--precompile-online",
        action="store_true",
        help="prepare the Julia online control method before launching the games",
    )
    return campaign(parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
