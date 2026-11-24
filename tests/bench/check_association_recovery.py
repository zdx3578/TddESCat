"""Verify confirmed tail batches, offline recovery, and fair public experiments."""

import sys
from collections import Counter
from dataclasses import replace
from hashlib import sha256
from pathlib import Path
from shutil import copytree

from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_env.bench.reference import available_actions, render_response, transition
from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import supervise
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_core_learning import captured_rows
from tests.bench.check_online import load, online_config


def verify_ledger(episode, scene, actions):
    previous = None
    state = scene.start_state
    events = captured_rows(episode, "events")
    assert len(events) == actions + 1
    for row in events:
        assert row["before_ref"] == previous
        action = row["action"]
        number = action["id"]
        assert number == 0 or number in available_actions(scene, state)
        command = (number, action["x"], action["y"]) if number == 6 else number
        outcome = transition(scene, state, command)
        expected = render_response(scene, state, command, outcome)
        body = episode / "blobs" / row["response_blob"]
        assert sha256(body.read_bytes()).hexdigest() == row["response_blob"]
        assert load(episode, body.relative_to(episode))["frame"] == expected
        state = outcome
        previous = row["event_id"]
    ledger = load(episode, "learning/dispositions.json")
    assert not ledger["pending"], ledger["pending"]
    rows = {row["event_ref"]: row for row in ledger["events"]}
    batches = []
    for job in sorted((episode / "learning").glob("job-*")):
        batch = load(job, "batch.json")
        selected = {ref for _, ref, _ in batch["inputs"]}
        batches.append(len(selected))
        for _, ref, digest in batch["inputs"]:
            assert rows[ref]["job"] == job.name and rows[ref]["response_blob"] == digest
            assert rows[ref]["complete"]
        if (job / "input/origins.json").exists():
            origins = load(job, "input/origins.json")
            assert {origin["event_ref"] for origin in origins} <= selected
            summary = load(job, "output/learning-summary.json")
            assert summary["effective_search_options"]["max_arity"] == 1000
            assert summary["termination_reason"] in {
                "verified_compression_fixed_point",
                "input_scope_incomplete",
            }
    assert set(rows) >= {row["event_id"] for row in events}
    return {"batch_sizes": batches, "events": len(events)}


def capture(root, url, scene, path, actions, batch, *, prior=None):
    path.mkdir(parents=True)
    cfg = path / "agent.toml"
    online_config(
        cfg, root, url, scene, budget=actions + 1, batch=batch, prior=prior, adapt=True
    )
    assert supervise(root, cfg, path) == 0, (path / "solver.log").read_text()
    return cfg


def recovery(root, original, clone):
    copytree(original, clone)
    commands = {p.name: p.read_bytes() for p in (clone / "commands").glob("*.json")}
    jobs = sorted((clone / "learning").glob("job-*"))
    final = jobs[-1]
    (final / "assessment.json").unlink()
    (final / "worker-status.json").unlink()
    (clone / "learning/dispositions.json").unlink()
    ref = load(final, "batch.json")["inputs"][-1][1]
    (clone / "learning/obligations" / f"{ref}.json").unlink()
    before = load(clone, "publication/current.json")
    cfg = original / "agent.toml"
    assert supervise(root, cfg, clone, recovery=True) == 0, (
        clone / "recovery.log"
    ).read_text()
    assert load(clone, "learning/dispositions.json") == load(
        original, "learning/dispositions.json"
    )
    dispositions = (clone / "learning/dispositions.json").read_bytes()
    assert supervise(root, cfg, clone, recovery=True) == 0
    assert (clone / "learning/dispositions.json").read_bytes() == dispositions
    assert sorted((clone / "learning").glob("job-*")) == jobs
    assert {
        p.name: p.read_bytes() for p in (clone / "commands").glob("*.json")
    } == commands
    assert load(clone, "publication/current.json") == before
    return {"jobs": len(jobs), "unchanged_commands": len(commands), "restored": ref}


def main(config, run):
    root = Path.cwd()
    runtime = runtime_paths(root)
    task = read_task(config)
    plans = read_plan(task["judge_config"])
    base = next(
        scene
        for scene in scenes(plans, plans["training_seeds"][0])
        if scene.variant == "open-wide"
    )
    base = replace(base, moves=((1, 1, 0),))
    win = replace(base, public_id=base.public_id + "1", goal=(8, 6))
    idle = replace(base, public_id=base.public_id + "2", active=(1, 3, 7, 13))
    fair = replace(base, public_id=base.public_id + "3", moves=((1, 1, 0), (2, -1, 0)))
    shifting = replace(fair, public_id=base.public_id + "4", dynamics="action-domain")
    games = run / "private/games"
    materialize(games, [base, win, idle, fair, shifting])
    public = run / "public"
    report = {}
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        run / "private/server",
        run / "grade/environment.log",
    ) as (url, _):
        for length in (2, 3, 4, 5, 7):
            path = (
                public / "prior/episode"
                if length == 7
                else public / f"actions-{length}"
            )
            capture(root, url, base, path, length, 3)
            report[str(length)] = verify_ledger(path, base, length)
            assert report[str(length)]["batch_sizes"] == [
                min(3, length - offset) for offset in range(0, length, 3)
            ]
        end = public / "win"
        capture(root, url, win, end, 7, 3)
        assert load(end, "public-run.json")["learned"]["state"] == "WIN"
        report["win"] = verify_ledger(end, win, 2)
        blocked = public / "same-response"
        capture(root, url, idle, blocked, 5, 3)
        report["identical_response"] = verify_ledger(blocked, idle, 5)
        counts = Counter(
            row["response_blob"] for row in captured_rows(blocked, "events")
        )
        assert max(counts.values()) >= 2
        report["identical_response"]["largest_duplicate_group"] = max(counts.values())
        fair_paths = {}
        for name, scene in (
            ("known-and-unknown", fair),
            ("action-domain-change", shifting),
        ):
            path = public / name
            capture(root, url, scene, path, 4, 3, prior=public / "prior")
            decisions = captured_rows(path, "decisions")
            assert decisions[0]["definition_refs"]
            assert decisions[1]["action"]["id"] == 2
            assert "definition_refs" not in decisions[1]
            assert (
                decisions[0]["experiment_obligation"]["round"]
                == decisions[1]["experiment_obligation"]["round"]
            )
            if scene == shifting:
                assert all(row["action"]["id"] == 2 for row in decisions[1:])
            fair_paths[name] = [row["action"] for row in decisions]
    report["recovery"] = recovery(root, public / "prior/episode", public / "restored")
    write_json(public / "learning-audit.json", report)
    write_json(public / "experiment-audit.json", fair_paths)
    append_assertion(run, "A01", True, ["public/learning-audit.json"])
    append_assertion(run, "A02", True, ["public/experiment-audit.json"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
