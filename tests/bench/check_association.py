"""Use a relation constructed from earlier public interventions in a held-out scene."""

import sys
from dataclasses import replace
from pathlib import Path

from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_env.bench.grade import finite_engine_check
from tddesc_env.bench.reference import render, transition
from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import supervise
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_composition import collect_training
from tests.bench.check_core_learning import captured_rows
from tests.bench.check_online import load, online_config


def fixture(base, index, x, y, marker, decoy, allow):
    other = (18, 5 + index % 3)
    near = (x + 1, y - 1)
    static = (
        ((*near, marker), (*other, decoy))
        if allow
        else ((*near, decoy), (*other, marker))
    )
    return replace(
        base,
        public_id=base.public_id + f"{index:02}",
        start=((x, y),),
        static=static,
        moves=((1, 1, 0), (2, 1, 0)),
        contact_rule=(1, marker),
    )


def verify(path, scene, action, training):
    before = load(path, "public-run.json")
    assert before["learned"]["frozen_before"] == before["learned"]["frozen_after"]
    decision = captured_rows(path, "decisions")
    feedback = captured_rows(path, "checks")
    assert len(decision) == len(feedback) == 1
    assert decision[0]["action"] == {"id": action}
    assert feedback[0]["assessments"] and all(
        value == "supported" for value in feedback[0]["assessments"].values()
    )
    ranked = next(
        item for item in decision[0]["candidates"] if item["action"]["id"] == 1
    )
    truth = "proven" if action == 1 else "disproven"
    reads = ranked["relation_reads"]
    assert reads and all(read["truth"] == truth for read in reads)
    relation = reads[0]
    certificate = load(
        path, f"publication/constructed/{relation['certificate_sha256']}.json"
    )["certificate"]
    assert certificate["kind"] == "constructed-query"
    assert set(certificate["recalled_events"]) <= training
    assert {row["verdict"] for row in certificate["comparison"]} == {
        "proven",
        "disproven",
    }
    assert all(
        row["dag"] and all(row["witnesses"]) for row in certificate["comparison"]
    )
    event = captured_rows(path, "events")[-1]
    body = load(path, "blobs/" + event["response_blob"])
    assert body["frame"] == [
        render(scene, transition(scene, scene.start_state, action))
    ]
    return {
        "action": action,
        "relation": relation,
        "training": certificate["recalled_events"],
        "confirmed_event": event["event_id"],
    }


def main(config, run):
    root = Path.cwd()
    runtime = runtime_paths(root)
    task = read_task(config)
    plan = read_plan(task["judge_config"])
    base = next(
        s for s in scenes(plan, plan["training_seeds"][0]) if s.variant == "open-square"
    )
    pigment = {base.background, base.letterbox, base.bodies[0][0][2]}
    marker, decoy, *_ = sorted(set(range(16)) - pigment)
    inputs = [
        fixture(base, i, 4 + i % 3, 6 + i // 3, marker, decoy, i != 1) for i in range(5)
    ]
    interventions = {
        scene.public_id: [1 if i < 2 else 2] for i, scene in enumerate(inputs)
    }
    tests = [
        fixture(base, 7, 8, 8, marker, decoy, True),
        fixture(base, 8, 8, 8, marker, decoy, False),
    ]
    games = run / "private/games"
    materialize(games, [*inputs, *tests])
    for scene in (*inputs, *tests):
        finite_engine_check(scene)
    public = run / "public"
    prior = public / "training"
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
            [(scene, 2) for scene in inputs],
            interventions=interventions,
        )
        event_refs = {
            row["event_id"]
            for episode in prior.glob("episode-*")
            for row in captured_rows(episode, "events")
            if row["action"]["id"] != 0
        }
        for index, scene in enumerate(tests, 1):
            path = public / f"held-out-{index}"
            path.mkdir()
            cfg = path / "agent.toml"
            online_config(
                cfg, root, url, scene, budget=2, prior=prior, association=True
            )
            assert supervise(root, cfg, path) == 0, (path / "solver.log").read_text()
            results.append(verify(path, scene, index, event_refs))
    write_json(public / "association.json", results)
    for gate in ("A04", "A05"):
        append_assertion(run, gate, True, ["public/association.json"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
