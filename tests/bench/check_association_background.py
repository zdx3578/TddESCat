"""Confirm public actions while a real learning task is queued."""

import sys
from dataclasses import replace
from pathlib import Path
from time import monotonic
from unittest.mock import patch

from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_tools import public_run
from tddesc_tools.isolation import environment_server
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_association_recovery import verify_ledger
from tests.bench.check_core_learning import captured_rows
from tests.bench.check_online import online_config


def main(config, run):
    root = Path.cwd()
    runtime = runtime_paths(root)
    task = read_task(config)
    plan = read_plan(task["judge_config"])
    base = next(
        scene
        for scene in scenes(plan, plan["training_seeds"][0])
        if scene.variant == "open-wide"
    )
    scene = replace(base, moves=((1, 1, 0),))
    games = run / "private/games"
    materialize(games, [scene])
    public = run / "public"
    path = public / "episode"
    path.mkdir()
    process_jobs = public_run.process_jobs
    evidence = {}
    held_since = None

    def hold_first_job(*args):
        nonlocal held_since
        ready = path / "learning/job-000001/input/manifest.json"
        status = path / "learning/job-000001/worker-status.json"
        if ready.is_file() and not status.exists():
            if held_since is None:
                held_since = monotonic()
            events = captured_rows(path, "events")
            if len(events) < 4 and monotonic() - held_since < 15:
                return
            evidence["confirmed_before_worker"] = len(events) - 1
        process_jobs(*args)

    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        run / "private/server",
        run / "grade/environment.log",
    ) as (url, _):
        cfg = path / "agent.toml"
        online_config(cfg, root, url, scene, budget=7, batch=2)
        cfg.write_text(
            cfg.read_text().replace(
                "[learning]\n", "[learning]\nbackground_search = true\n", 1
            )
        )
        with patch.object(public_run, "process_jobs", hold_first_job):
            assert public_run.supervise(root, cfg, path) == 0, (
                path / "solver.log"
            ).read_text()
    evidence.update(verify_ledger(path, scene, 6))
    assert evidence["confirmed_before_worker"] >= 3
    assert evidence["batch_sizes"] == [2, 2, 2]
    decisions = captured_rows(path, "decisions")
    assert decisions[2]["pending_learning_job"] == "job-000001"
    evidence["decision"] = decisions[2]["command_id"]
    write_json(public / "background.json", evidence)
    append_assertion(run, "background_learning", True, ["public/background.json"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
