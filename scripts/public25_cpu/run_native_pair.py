"""Run the two Public25 comparison games from the prepared baseline checkout."""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import subprocess

from scripts import evaluate_public25 as api


GAMES = ("lf52-271a04aa", "wa30-ee6fef47")
BASELINE = "59efbcd5299e2cd0e6bf85b23f4e82fb65bb0e86"


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--bundle", required=True, type=Path)
    cli.add_argument("--output", required=True, type=Path)
    cli.add_argument("--candidate", required=True, type=Path)
    args = cli.parse_args()
    bundle, output, candidate = (p.resolve() for p in (args.bundle, args.output, args.candidate))
    ref = json.loads((candidate / "manifest.json").read_bytes())
    root = api.ROOT
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    if revision != BASELINE or ref["execution_mode"] != "native_docker":
        raise ValueError("Expected the pinned baseline and a native Docker candidate")
    suite = api.read_task(root / "config/acceptance/arc_public25.toml")
    if not set(GAMES) <= set(suite["game_ids"]) & set(ref["game_ids"]):
        raise ValueError("Paired game is missing")
    template = root / "config/v13_public25.toml"
    if (
        api.sha256_file(template) != ref["profile_sha256"]
        or api.sha256_file(bundle / "offline_public_games_manifest.json") != ref["catalog_sha256"]
    ):
        raise ValueError("Candidate and baseline inputs differ")
    available = sorted(os.sched_getaffinity(0) - set(ref["cpu_assignment"].values()))
    if len(available) < len(GAMES):
        raise ValueError("The two baseline cases need two additional CPUs")
    cpus = dict(zip(GAMES, available[: len(GAMES)], strict=True))
    runtime = api.runtime_paths(root)
    output.mkdir(parents=True, exist_ok=False)
    engine, policy = api.prepare_cases(output, GAMES, template, suite, bundle, native_docker=True)
    if api.build_identity(root, engine) != ref["engine"] or api.sha256_file(policy) != ref["policy_sha256"]:
        raise ValueError("Candidate and baseline learning settings differ")
    api.atomic_json(
        output / "manifest.json",
        {
            "commit": revision,
            "execution_mode": "native_docker",
            "game_ids": GAMES,
            "cpu_assignment": cpus,
            "command_budget": "unlimited",
            "paired_candidate": str(candidate),
            "worktree_sha256": api.worktree_digest(root),
            "online_runtime": api.prepare_online_runtime(runtime),
            "profile_sha256": ref["profile_sha256"],
            "catalog_sha256": ref["catalog_sha256"],
        },
    )
    report = output / "public25.json"
    results = {}
    api.atomic_json(report, api.campaign_report(GAMES, results))
    with ThreadPoolExecutor(max_workers=len(GAMES)) as pool:
        pending = {
            pool.submit(
                api.evaluate_game, output / game, game, runtime, native_docker=True, cpu=cpus[game]
            ): game
            for game in GAMES
        }
        for task in as_completed(pending):
            game = pending[task]
            try:
                row = task.result()
            except Exception as exc:
                row = {"game_id": game, "error": f"{type(exc).__name__}: {exc}"}
            row["verdict"] = api.game_verdict(row)
            results[game] = row
            api.atomic_json(report, api.campaign_report(GAMES, results))
            print(game, row["verdict"], flush=True)


if __name__ == "__main__":
    main()
