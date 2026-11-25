"""Use a discovered measurement program as a verified goal candidate."""

import sys
from dataclasses import replace
from pathlib import Path
from shutil import copytree

from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import supervise
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_composition import collect_training
from tests.bench.check_core_learning import captured_rows
from tests.bench.check_measurement import display_scene
from tests.bench.check_online import load, online_config
from tests.bench.check_sequence_learning import check_scene


def goal_scene(base, y, suffix, *, marker=None):
    scene = display_scene(base, start=(2, 2 if y == 7 else 3), suffix=suffix)
    gate = tuple((x, row) for x in range(4, 13) for row in (y, y + 1))
    return replace(
        scene,
        start=((5 if marker is not None else 6, y),),
        moves=((1, 1, 0), (2, -1, 0)),
        resource=replace(scene.resource, gate_cells=gate),
        static=(*scene.static, (marker, y, 8)) if marker is not None else scene.static,
    )


def recover_publication(root, original, clone, job):
    copytree(original, clone)
    attempt = clone / "learning" / job
    original_publication = load(attempt, "program-publication.json")
    (attempt / "assessment.json").unlink()
    files = {f.name: f.read_bytes() for f in (clone / "commands").glob("*.json")}
    jobs = sorted((clone / "learning").glob("job-*"))
    current = load(clone, "publication/current.json")
    cfg = original / "agent.toml"
    assert supervise(root, cfg, clone, recovery=True) == 0, (
        clone / "recovery.log"
    ).read_text()
    assert (
        load(attempt, "assessment.json")["publication"]
        == original_publication["publication"]
    )
    assert load(clone, "publication/current.json") == current
    assert load(attempt, "program-publication.json") == original_publication
    assert sorted((clone / "learning").glob("job-*")) == jobs
    assert supervise(root, cfg, clone, recovery=True) == 0
    assert {
        f.name: f.read_bytes() for f in (clone / "commands").glob("*.json")
    } == files
    assert load(clone, "publication/current.json") == current
    return {"job": job, "restored": original_publication, "public_commands": len(files)}


def main(config, run):
    root = Path.cwd()
    task = read_task(config)
    runtime = runtime_paths(root)
    plan = read_plan(task["judge_config"])
    base = next(
        s for s in scenes(plan, plan["training_seeds"][0]) if s.variant == "open-square"
    )
    previous = [goal_scene(base, 7 if i % 2 else 10, f"G{i:02}") for i in range(10)]
    decoys = [goal_scene(base, 7 if i % 2 else 10, f"D{i:02}") for i in range(8)]
    extension = [
        replace(goal_scene(base, 7, f"E{i:02}"), start=((8, 7),)) for i in range(8)
    ]
    held = [goal_scene(base, y, f"G{91 + i}", marker=10) for i, y in enumerate((7, 10))]
    held.append(goal_scene(base, 7, "G93", marker=11))
    games = run / "private/games"
    materialize(games, [*previous, *decoys, *extension, *held])
    public = run / "public"
    prior = public / "previous"
    results = []
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        run / "private/server",
        run / "grade/environment.log",
    ) as (url, _):
        collect_training(
            root,
            runtime,
            url,
            prior,
            [(scene, 3) for scene in previous]
            + [(scene, 2) for scene in (*decoys, *extension)],
            interventions={
                **{scene.public_id: [1, 1] for scene in previous},
                **{scene.public_id: [5] for scene in decoys},
                **{scene.public_id: [1] for scene in extension},
            },
        )
        for i, scene in enumerate(held):
            path = public / f"held-{i}"
            path.mkdir()
            cfg = path / "agent.toml"
            online_config(
                cfg,
                root,
                url,
                scene,
                prior=prior,
                sequences=True,
                goal=(5, 8),
                budget=7,
            )
            assert supervise(root, cfg, path) == 0, (path / "solver.log").read_text()
            events = check_scene(path, scene)
            assert load(path, "public-run.json")["learned"]["goal"] == "observed"
            subgoal = i == 2
            assert [event["action"]["id"] for event in events] == [0] + [1] * (
                4 if subgoal else 3
            )
            checks = captured_rows(path, "checks")
            decisions = captured_rows(path, "decisions")
            contract = "goal_predecessor" if subgoal else "distance_to_marker"
            completed = [
                (d, c)
                for d, c in zip(decisions, checks, strict=True)
                if c.get("program")
                and c["program"]["feedback"] in ("advance", "completed")
                and c["program"]["goal"]["contract"] == contract
            ]
            assert len(completed) == 2, [
                (d["reason"], c.get("program")) for d, c in zip(decisions, checks)
            ]
            scope_instances = []
            for decision, check in completed:
                program = check["program"]
                assert program["goal"]["contract"] == contract
                assert decision["reason"] == "revalidated_learned_program"
                assert program["ordinary_action"] == decision["candidates"][0]["action"]
                assert set(check["assessments"].values()) == {"supported"}
                (meter,) = [
                    effect["context"]["instance"]
                    for effect in check["evidence"]["effects"]
                    if effect["family"] == "measurement"
                ]
                scope_instances.append(meter)
            if subgoal:
                asserted = completed[-1][1]["program"]["goal"]["continuation"][0]
                assert tuple(asserted["action"]) == (1, -1, -1)
                assert asserted["expected"] == checks[-1]["expected"]
                assert set(checks[-1]["assessments"].values()) == {"supported"}
                if terminal := checks[-1]["program"]:
                    assert terminal["goal"]["contract"] == "distance_to_marker"
                    assert (
                        terminal["feedback"] == "completed"
                        and terminal["terminated_at_goal"]
                    )
            assert len(set(scope_instances)) == 1
            results.append(
                {
                    "instance": scope_instances[0],
                    "goal": completed[-1][1]["program"]["goal"],
                    "proof": [check["program"] for _, check in completed],
                    "changes_ordinary_choice": any(
                        check["action"] != check["program"]["ordinary_action"]
                        for _, check in completed
                    ),
                }
            )
    assert results[0]["instance"] != results[1]["instance"]
    assert results[0]["proof"][0]["definition"] == results[1]["proof"][0]["definition"]
    assert all(result["changes_ordinary_choice"] for result in results)
    path = public / "held-0"
    learned_job = next(
        job
        for job in (path / "learning").glob("job-*")
        if (job / "program-publication.json").is_file()
    )
    restored = recover_publication(root, path, public / "restored", learned_job.name)
    write_json(
        public / "measurement-goal.json", dict(bindings=results, recovery=restored)
    )
    for name in ("measurement_goal_execution", "program_publication_recovery"):
        append_assertion(run, name, True, ["public/measurement-goal.json"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
