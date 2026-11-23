"""Frozen public-interface tests of the six elementary learned mechanisms."""

import json
import sys
from dataclasses import replace
from pathlib import Path
from time import monotonic

from tddesc_env.bench import reference
from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_env.bench.grade import finite_engine_check
from tddesc_tools.contracts import Contracts
from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import supervise
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_evidence import solver_process
from tests.bench.check_online import load, online_config

CASES = {
    "M01": (("open-wide", 4, 2),),
    "M02": (("wide-corridor", 4, 2), ("narrow-corridor", 2, 2)),
    "M04": (("push-open", 4, 2), ("push-blocked", 2, 2)),
    "M05": (("panel-open", 4, 2), ("panel-toggle", 4, 4)),
    "M06": (("resource-one", 3, 2), ("resource-two", 3, 2), ("resource-zero", 2, 2)),
    "M08": (("click-interior", 4, 6),),
}

DIRECTION_REMAP = {1: 3, 2: 4, 3: 1, 4: 2}


def heldout(by_name, case):
    if case == "M01":
        original = by_name["open-wide"]
        return replace(original, public_id=original.public_id + "1", start=((4, 7),))
    if case == "M02":
        original = by_name["wide-corridor"]
        return replace(original, public_id=original.public_id + "1", start=((4, 6),))
    if case == "M04":
        original = by_name["push-open"]
        return replace(
            original, public_id=original.public_id + "1", start=((4, 6), (6, 6))
        )
    if case == "M05":
        original = by_name["panel-toggle"]
        return replace(
            original, public_id=original.public_id + "1", moves=((1, 1, 0), (2, -1, 0))
        )
    if case == "M06":
        original = by_name["resource-one"]
        contrast = next(
            color
            for color in range(16)
            if color not in (original.background, original.letterbox)
        )
        return replace(
            original,
            public_id=original.public_id + "1",
            static=(*original.static, (20, 3, contrast)),
        )
    return by_name["click-viewport21"]


def with_push(scene, push_example):
    gate_x, gate_y = scene.switch.gate_cells[0]
    independently_visible = tuple(
        (x, y, scene.switch.on_color) for x, y, _ in push_example.bodies[1]
    )
    return replace(
        scene,
        public_id=scene.public_id + "2",
        bodies=(scene.bodies[0], independently_visible),
        start=(*scene.start, (gate_x, gate_y)),
        pushable=True,
    )


def relabel_scene(scene):
    def remap(action):
        return DIRECTION_REMAP.get(action, action)

    return replace(
        scene,
        moves=tuple((remap(action), dx, dy) for action, dx, dy in scene.moves),
        prefix=tuple(
            remap(action) if isinstance(action, int) else action
            for action in scene.prefix
        ),
    )


def captured_rows(episode, folder):
    return [
        json.loads(path.read_bytes())
        for path in sorted((episode / folder).glob("*.json"))
    ]


def verify_core(
    root, episode, scene, case, *, planning=False, joint_push=False, direction=1
):
    result = load(episode, "public-run.json")
    summary = result["learned"]
    assert result["prior_publication"] and summary["models"] > 0
    assert summary["frozen_before"] == summary["frozen_after"]
    assert not summary["publications"]
    checkpoints = captured_rows(episode, "checks")
    assert not any(c["revisions"] for c in checkpoints)
    decisions = captured_rows(episode, "decisions")
    predicted = [
        c
        for c in checkpoints
        if c["expected"] and set(c["assessments"].values()) == {"supported"}
    ]
    assert predicted, [row["coverage"] for row in checkpoints]
    assert all(row["definition_refs"] for row in predicted)
    contracts = Contracts(root / "protocol/v1")
    for row in captured_rows(episode, "predictions"):
        contracts.validate("prediction", row)
    actual = scene.start_state
    for event in captured_rows(episode, "events"):
        action = event["action"]
        cmd = (6, action["x"], action["y"]) if action["id"] == 6 else action["id"]
        actual = reference.transition(scene, actual, cmd)
        assert load(episode, "blobs/" + event["response_blob"])["frame"] == [
            reference.render(scene, actual)
        ]
    first = predicted[0]
    if case == "M04":
        assert len(first["expected"]) == 2
        assert all(key.startswith("translation-") for key in first["expected"])
    elif case == "M05":
        assert decisions[0]["reason"] == "establishes_observed_condition", decisions[0]
        assert [row["action"]["id"] for row in predicted[:2]] == [5, direction]
        assert list(first["expected"])[0].startswith("pigment-")
        if joint_push:
            assert len(predicted[1]["expected"]) == 2
            assert all(
                key.startswith("translation-") for key in predicted[1]["expected"]
            )
        if planning:
            prefix, suffix = decisions[:2]
            assert prefix["policy"]["operation"] == "freeze_projected_policy"
            assert len(prefix["policy"]["dependencies"]) == 2
            assert suffix["reason"] == "revalidated_policy_step", suffix
            assert suffix["policy"]["parent_command"] == prefix["command_id"]
            assert suffix["before_ref"] == first["event_ref"]
            assert suffix["policy"]["status"] == "ready", suffix["policy"]
    elif case == "M06":
        values = first["expected"]
        assert any(k.startswith("count-") and v == 0 for k, v in values.items())
        assert any(
            k.startswith("translation-") and v == [2, 0] for k, v in values.items()
        )
        assert "resource_precondition" in decisions[1]["candidates"][-1]["reason"]
    elif case == "M08":
        assert [row["action"]["id"] for row in predicted[:2]] == [6, direction], (
            predicted[:2]
        )
        assert decisions[0]["reason"] == "tests_changed_role_selection"
        chosen = next(iter(first["expected"].values()))
        assert any(
            key == f"translation-{chosen[0]}-{chosen[1]}"
            for key in predicted[1]["expected"]
        )
    else:
        assert any(key.startswith("translation-") for key in first["expected"])
    return {
        "model_digest": summary["frozen_before"],
        "publication": result["prior_publication"],
        "checked_predictions": len(predicted),
        "first": first["expected"],
        "probed_actions": [row["action"] for row in checkpoints],
        "wrong_confidence": sum(
            "refuted" in row["assessments"].values() for row in checkpoints
        ),
        "round_trip_seconds": [row["round_trip_seconds"] for row in checkpoints],
    }


def check_withdrawal(episode):
    action = captured_rows(episode, "decisions")
    feedback = captured_rows(episode, "checks")
    assert action[0]["policy"]["operation"] == "freeze_projected_policy"
    assert feedback[0]["policy"]["feedback"] == "withdrawn_after_feedback"
    assert "refuted" in feedback[0]["assessments"].values()
    assert feedback[0]["revisions"]
    assert len(action) > 1 and action[1]["before_ref"] == feedback[0]["event_ref"]
    assert action[1]["action"]["id"] != action[0]["policy"]["next"]["id"]
    assert action[1]["reason"] != "revalidated_policy_step"
    return {
        "policy": action[0]["policy"],
        "counterexample": feedback[0]["event_ref"],
        "revisions": feedback[0]["revisions"],
        "next": action[1]["action"],
    }


def main(config, run):
    root = Path.cwd()
    task = read_task(config)
    runtime = runtime_paths(root)
    plan = read_plan(task["judge_config"])
    covariance = task["kind"] == "movement_covariance"
    seed = plan["training_seeds"][1 if covariance else 0]
    by_name = {s.variant: s for s in scenes(plan, seed)}
    click_training = by_name["click-interior"]
    by_name["click-interior"] = replace(click_training, moves=((1, 1, 0),))
    joint_push = task["kind"] == "planning_composition"
    planning = task["kind"] == "planning_public" or joint_push
    selected = {"M05": CASES["M05"]} if planning else CASES
    if covariance:
        selected = {case: CASES[case] for case in ("M05", "M08")}
        for variant in ("panel-open", "panel-toggle"):
            scene = by_name[variant]
            by_name[variant] = replace(
                scene, switch=replace(scene.switch, panel=(20, 1))
            )
    if joint_push:
        for variant in ("panel-open", "panel-toggle"):
            by_name[variant] = with_push(by_name[variant], by_name["push-open"])
    targets = {case: heldout(by_name, case) for case in selected}
    if covariance:
        by_name = {name: relabel_scene(scene) for name, scene in by_name.items()}
        targets = {case: relabel_scene(scene) for case, scene in targets.items()}
    all_scenes = {s.public_id: s for s in [*by_name.values(), *targets.values()]}
    if joint_push:
        target = targets["M05"]
        decoy = replace(
            target, public_id=target.public_id + "3", dynamics="decoy-switch"
        )
        all_scenes[decoy.public_id] = decoy
    private = run / "private"
    games = private / "games"
    materialize(games, list(all_scenes.values()))
    for scene in targets.values():
        assert finite_engine_check(scene)["transitions"] > 0
    public = run / "public"
    training = public / "training"
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        private / "server",
        run / "grade/environment.log",
    ) as (url, _):
        plans = []
        for case, contexts in selected.items():
            count = 0
            for variant, repeats, budget in contexts:
                for _ in range(repeats):
                    count += 1
                    episode = training / case / f"episode-{count:03d}"
                    episode.mkdir(parents=True)
                    cfg = episode / "agent.toml"
                    online_config(
                        cfg, root, url, by_name[variant], budget=budget, collection=True
                    )
                    plans.append({"config": str(cfg), "public": str(episode)})
        train_list = training / "public-inputs.json"
        write_json(train_list, plans)
        sampler = root / "tests/julia/collect_public.jl"
        results = solver_process(
            root,
            runtime,
            training,
            str(train_list),
            script=sampler,
            extra_read=(root / "scripts/run.jl",),
        )
        (run / "grade/training.log").write_text(results.stdout + results.stderr)
        assert results.returncode == 0, results.stderr
        for case, scene in targets.items():
            started = monotonic()
            episode = public / case
            episode.mkdir()
            cfg = episode / "agent.toml"
            online_config(
                cfg,
                root,
                url,
                scene,
                budget=2 if case in ("M01", "M02", "M04") else 3,
                prior=training / case,
                planning=planning,
            )
            code = supervise(root, cfg, episode)
            assert code == 0, (episode / "solver.log").read_text()
            summary = verify_core(
                root,
                episode,
                scene,
                case,
                planning=planning,
                joint_push=joint_push,
                direction=DIRECTION_REMAP[1] if covariance else 1,
            )
            summary["wall_seconds"] = monotonic() - started
            summary["fixture"] = scene.variant
            if covariance:
                summary["palette_seed"] = seed
                summary["action_number_map"] = DIRECTION_REMAP
            write_json(episode / "verified.json", summary)
            assert summary["wrong_confidence"] == 0, summary
            append_assertion(
                run,
                "guard_then_joint_push"
                if joint_push
                else "public_revalidated_policy"
                if planning
                else case,
                True,
                [f"public/{case}/verified.json", f"public/{case}/solver-usage.txt"],
            )
        if joint_push:
            episode = public / "counterexample"
            episode.mkdir()
            cfg = episode / "agent.toml"
            online_config(
                cfg,
                root,
                url,
                decoy,
                budget=3,
                prior=training / "M05",
                planning=True,
                adapt=True,
            )
            assert supervise(root, cfg, episode) == 0, (
                episode / "solver.log"
            ).read_text()
            write_json(episode / "verified.json", check_withdrawal(episode))
            append_assertion(
                run,
                "plan_withdrawal",
                True,
                [
                    "public/counterexample/verified.json",
                    "public/counterexample/solver-usage.txt",
                ],
            )


if __name__ == "__main__":
    main(*(Path(arg) for arg in sys.argv[1:]))
