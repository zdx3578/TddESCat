"""Learn ordered programs from confirmed public episodes and execute their steps."""

import sys
from dataclasses import replace
from pathlib import Path

from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_env.bench.grade import finite_engine_check
from tddesc_env.bench.reference import render, transition
from tddesc_env.bench.scenario import Resource
from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import supervise
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_composition import collect_training
from tests.bench.check_core_learning import captured_rows
from tests.bench.check_online import load, online_config


def inspect_learning(path, prior):
    phases = []
    all_refs = {
        row["event_id"]
        for episode in prior.glob("episode-*")
        for row in captured_rows(episode, "events")
        if row["action"]["id"] != 0
    }
    for job in sorted((path / "learning").glob("job-*")):
        corpus = job / "sequence-corpus.json"
        if not corpus.is_file():
            continue
        candidate = load(job, "sequence-corpus.json")
        history = [ref for scope in candidate["scopes"] for ref in scope["events"]]
        assert set(history) <= all_refs and len(set(history)) == len(history)
        result = load(job, "assessment.json")
        assert result["result"] == "published" and result["programs"], result
        bundle = load(path, f"publication/{result['publication']}.json")
        assert set(result["programs"]) <= set(bundle["new_definition_ids"])
        assert bundle["semantic_context"]["intent"] == "program"
        cost = bundle["cost"]
        assert int(cost["final_total"]) < int(cost["ratio_numerator"])
        phases.append(
            {
                "publication": result["publication"],
                "programs": result["programs"],
                "depth": max(
                    bundle["definition_depths"][ref] for ref in result["programs"]
                ),
                "cost": cost,
                "sources": history,
            }
        )
    assert len(phases) == 2
    assert phases[1]["depth"] > phases[0]["depth"], phases
    return phases


def check_scene(path, scene):
    state = scene.start_state
    events = captured_rows(path, "events")
    for event in events:
        state = transition(scene, state, event["action"]["id"])
        actual = load(path, "blobs/" + event["response_blob"])
        assert actual["frame"] == [render(scene, state)]
    return events


def resource_program_scenes(base):
    x, y = 6, 6
    used = {base.background, base.letterbox}
    used.update(color for body in base.bodies for _, _, color in body)
    marker, token, *_ = sorted(set(range(16)) - used)
    base = replace(
        base,
        active=(1, 3, 15, 13),
        start=((x, y), (x + 2, y)),
        static=(),
        blocked=(),
        resource=Resource(
            (14, 1), ((x + 2, y), (x + 2, y + 1), (x, y), (x, y + 1)), token, 3
        ),
    )
    previous = [
        replace(
            base, public_id=base.public_id + f"{i:02}", static=((17, 3 + i, marker),)
        )
        for i in range(8)
    ]
    return previous, replace(
        base, public_id=base.public_id + "99", static=((20, 12, marker),)
    )


def run_resource_program(root, runtime, url, public, previous, target):
    prior = public / "resource-training"
    collect_training(
        root,
        runtime,
        url,
        prior,
        [(scene, 3) for scene in previous],
        interventions={scene.public_id: [1, 2] for scene in previous},
    )
    path = public / "resource-held-out"
    path.mkdir()
    cfg = path / "agent.toml"
    online_config(cfg, root, url, target, budget=3, prior=prior, sequences=True)
    assert supervise(root, cfg, path) == 0, (path / "solver.log").read_text()
    check_scene(path, target)
    feedback = captured_rows(path, "checks")
    assert [row["action"]["id"] for row in feedback] == [1, 2]
    assert all(set(row["assessments"].values()) == {"supported"} for row in feedback)
    assert [len(row["expected"]) for row in feedback] == [3, 2]
    assert all(row["program"] for row in feedback)
    assert feedback[-1]["program"]["feedback"] == "completed"
    counts = [
        [value for key, value in row["expected"].items() if key.startswith("count-")]
        for row in feedback
    ]
    assert counts == [[2], [1]]
    job = next(path.glob("learning/job-*/sequence-corpus.json"))
    corpus = load(job.parent, job.name)
    for scope in corpus["scopes"]:
        before, after = scope["steps"]
        assert any(
            before["effects"][i]["family"] == after["effects"][j]["family"] == "count"
            for i, j in scope["shared"][0]
        )
    return {"shared_count": counts, "checks": feedback}


def main(config, run):
    root = Path.cwd()
    runtime = runtime_paths(root)
    task = read_task(config)
    plan = read_plan(task["judge_config"])
    base = next(
        s for s in scenes(plan, plan["training_seeds"][0]) if s.variant == "open-square"
    )
    base = replace(base, start=((6, 6),), moves=((1, 1, 0), (2, -1, 0)))
    inputs = [
        replace(
            base,
            public_id=base.public_id + f"{index:02}",
            start=((5 + index % 5, 5 + index // 5),),
        )
        for index in range(18)
    ]
    held = replace(base, public_id=base.public_id + "91", start=((8, 9),))
    blocked = replace(
        held,
        public_id=base.public_id + "92",
        contact_rule=(1, (base.background + 1) % 16),
    )
    resource_base = next(
        scene
        for scene in scenes(plan, plan["training_seeds"][0])
        if scene.variant == "push-open"
    )
    resource_training, resource_target = resource_program_scenes(resource_base)
    games = run / "private/games"
    materialize(games, [*inputs, held, blocked, *resource_training, resource_target])
    for scene in (held, blocked, resource_target):
        finite_engine_check(scene)
    public = run / "public"
    prior = public / "training"
    reports = {}
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        run / "private/server",
        run / "grade/environment.log",
    ) as (url, _):
        interventions = {
            scene.public_id: [2, 1] if i < 6 else [2, 1, 2, 1]
            for i, scene in enumerate(inputs)
        }
        collect_training(
            root,
            runtime,
            url,
            prior,
            [(scene, 5) for scene in inputs],
            interventions=interventions,
        )
        for name, scene in (("held-out", held), ("refuted", blocked)):
            path = public / name
            path.mkdir()
            cfg = path / "agent.toml"
            online_config(cfg, root, url, scene, budget=5, prior=prior, sequences=True)
            assert supervise(root, cfg, path) == 0, (path / "solver.log").read_text()
            events = check_scene(path, scene)
            assert len(events) == 5
            feedback = captured_rows(path, "checks")
            observed = [row["action"]["id"] for row in feedback]
            notes = [row["program"] for row in feedback]
            assert feedback[0]["consumed_definition_depth"] >= 3
            if name == "held-out":
                reports["discovery"] = inspect_learning(path, prior)
                assert observed == [2, 1, 2, 1], observed
                assert [note["feedback"] for note in notes] == [
                    "advance",
                    "advance",
                    "advance",
                    "completed",
                ]
            else:
                assert observed[:2] == [2, 1]
                assert notes[1]["feedback"] == "effect_refuted_or_unknown", notes
                assert notes[1]["withdrawn_suffix"] == [3, 4]
                assert all(note is None for note in notes[2:])
            reports[name] = {"actions": observed, "program": notes}
        reports["resource"] = run_resource_program(
            root, runtime, url, public, resource_training, resource_target
        )
    write_json(public / "sequences.json", reports)
    for identifier in (
        "sequence_discovery",
        "sequence_consumption",
        "sequence_withdrawal",
        "sequence_resource",
    ):
        append_assertion(run, identifier, True, ["public/sequences.json"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
