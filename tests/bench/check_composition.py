"""Use frozen, independently collected public mechanisms to control new scenes."""

import sys
from dataclasses import replace
from pathlib import Path

from tddesc_env.bench import reference
from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_env.bench.grade import finite_engine_check, http_trace
from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import supervise
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_core_learning import captured_rows
from tests.bench.check_evidence import solver_process
from tests.bench.check_online import load, online_config


def goal_palette(scene, point):
    occupied = {scene.background, scene.letterbox}
    occupied.update(color for _, _, color in scene.static)
    occupied.update(color for body in scene.bodies for _, _, color in body)
    if scene.switch is not None:
        occupied.update((scene.switch.on_color, scene.switch.off_color))
    if scene.resource is not None:
        occupied.add(scene.resource.color)
    pigment = next(color for color in range(16) if color not in occupied)
    goal = (scene.bodies[0][0][2], pigment)
    return replace(scene, goal=point, static=(*scene.static, (*point, pigment))), goal


def switch_circuit(table):
    base = table["panel-toggle"]
    push = table["push-open"]
    gate, y = base.switch.gate_cells[0]
    scene, goal = goal_palette(
        replace(
            base,
            case="C01",
            variant="gate-then-push",
            public_id=base.public_id + "6",
            bodies=(base.bodies[0], push.bodies[1]),
            start=(*base.start, (gate + 1, y)),
            moves=((1, 1, 0), (2, -1, 0)),
            pushable=True,
            prefix=(5, 1, 1, 1),
        ),
        (gate + 2, y + 2),
    )
    conflict = (gate + 3, y + 1)
    narrow = replace(
        scene,
        variant="narrow-exit",
        public_id=scene.public_id + "1",
        blocked=(*scene.blocked, conflict),
        static=(*scene.static, (*conflict, base.switch.on_color)),
    )
    unknown = replace(
        scene,
        variant="offscreen-switch",
        public_id=scene.public_id + "2",
        viewport=(0, 4, scene.logical_size[0], 12),
        prefix=(1,),
    )
    training = []
    for name, repeats, budget in (
        ("panel-open", 4, 2),
        ("panel-toggle", 4, 4),
        ("push-open", 4, 2),
        ("wide-corridor", 3, 2),
        ("narrow-corridor", 2, 2),
    ):
        source = table[name]
        narrow_domain = replace(source, moves=((1, 1, 0),))
        training.extend((narrow_domain, budget) for _ in range(repeats))
    return training, (scene, narrow, unknown), goal


def collect_training(root, runtime, url, run, sessions):
    plans = []
    for index, (scene, budget) in enumerate(sessions, 1):
        episode = run / f"episode-{index:02d}"
        episode.mkdir(parents=True)
        config = episode / "agent.toml"
        online_config(config, root, url, scene, budget=budget, collection=True)
        plans.append({"config": str(config), "public": str(episode)})
    train_list = run / "public-inputs.json"
    write_json(train_list, plans)
    result = solver_process(
        root,
        runtime,
        run,
        str(train_list),
        script=root / "tests/julia/collect_public.jl",
        extra_read=(root / "scripts/run.jl",),
    )
    (run / "collect.log").write_text(result.stdout + result.stderr)
    assert result.returncode == 0, result.stderr


def shared_token(table):
    base = table["resource-one"]
    x, y = base.start[0]
    gates = tuple((u, v) for u in (x - 1, x + 2) for v in (y, y + 1))
    resource = replace(base.resource, gate_cells=gates)
    room = replace(
        base,
        case="C02",
        variant="shared-resource",
        public_id=base.public_id + "6",
        static=(),
        blocked=(),
        resource=resource,
        moves=((1, 1, 0), (2, -1, 0)),
        prefix=(2, 2),
    )
    scene, goal = goal_palette(room, (x - 2, y + 2))
    empty = replace(
        scene,
        variant="empty-resource",
        public_id=scene.public_id + "1",
        resource=replace(resource, initial=0),
        prefix=(1, 2),
    )
    training = []
    for action, dx in ((1, 1), (2, -1)):
        for shared, start_x in ((True, x), (False, x + dx)):
            variant = replace(
                room,
                public_id=room.public_id + str(action) + str(int(shared)),
                variant=f"resource-{action}-{int(shared)}",
                resource=resource if shared else None,
                start=((start_x, y),),
                moves=((action, dx, 0),),
                prefix=(action,),
            )
            training.extend((variant, 2) for _ in range(4))
    return training, (scene, empty), goal


def reachable_after_wrong_turn(scene):
    right = reference.transition(scene, scene.start_state, 1)
    left = reference.transition(scene, scene.start_state, 2)
    assert right.resource == left.resource == 0
    assert right.positions != left.positions
    assert not any(
        reference.goal_reached(scene, state)
        for state in reference.reachable(scene, right)
    )
    assert any(
        reference.goal_reached(scene, state)
        for state in reference.reachable(scene, left)
    )


def projected_path_exists(plan, source):
    goal_ids = {state["id"] for state in plan["states"] if state["goal"]}
    seen = set()
    queue = [source]
    while queue:
        state = queue.pop()
        if state in goal_ids:
            return True
        if state not in seen:
            seen.add(state)
            queue.extend(
                edge["after"] for edge in plan["edges"] if edge["before"] == state
            )
    return False


def audit_episode(path, scene):
    state = scene.start_state
    commands = []
    for record in captured_rows(path, "events"):
        action = record["action"]
        number = action["id"]
        arg = (number, action["x"], action["y"]) if number == 6 else number
        state = reference.transition(scene, state, arg)
        body = load(path, "blobs/" + record["response_blob"])
        assert body["frame"][-1] == reference.render(scene, state)
        won = reference.goal_reached(scene, state)
        assert body["state"] == ("WIN" if won else "NOT_FINISHED")
        assert body["levels_completed"] == int(won)
        if number:
            commands.append(arg)
    decisions = captured_rows(path, "decisions")
    assert len(decisions) == len(commands)
    checks = captured_rows(path, "checks")
    assert len(checks) == len(commands)
    for decision, check in zip(decisions, checks, strict=True):
        assert decision["action"] == check["action"]
    published = load(path, "public-run.json")
    learned = published["learned"]
    assert published["prior_publication"]
    assert learned["frozen_before"] == learned["frozen_after"]
    return commands, decisions, checks, learned


def audit_switch(path, scene, positive):
    commands, decisions, checks, learned = audit_episode(path, scene)
    plans = captured_rows(path, "plans")
    counts = [row["policy"]["operation"] for row in decisions]
    if positive:
        assert learned["state"] == "WIN" and learned["goal"] == "observed", (
            commands,
            counts,
        )
        initial, *suffix = decisions
        assert initial["policy"]["operation"] == "freeze_observed_goal_policy", initial
        plan = load(path, initial["policy"]["artifact"])
        assert len(plan["steps"]) == 4
        assert commands == [edge["action"][0] for edge in plan["steps"]] == [5, 1, 1, 1]
        assert all(step["reason"] == "revalidated_goal_policy" for step in suffix)
        assert all(
            step["policy"]["parent_command"] == initial["command_id"] for step in suffix
        )
        assert all(
            row["definition_refs"] and set(row["assessments"].values()) == {"supported"}
            for row in checks
        )
        assert checks[-1]["policy"]["feedback"] == "achieved"
        assert [len(row["expected"]) for row in checks] == [1, 1, 2, 2]
    else:
        assert learned["state"] != "WIN"
        assert "freeze_observed_goal_policy" not in counts, counts
        assert all(plan["status"] != "policy" for plan in plans), plans
    return {
        "goal": learned["goal"],
        "trace": commands,
        "decision_operations": counts,
        "prediction_scopes": [row["expected"] for row in checks],
    }


def audit_resource(path, scene, positive):
    commands, decisions, checks, learned = audit_episode(path, scene)
    if not positive:
        assert learned["state"] != "WIN"
        plans = captured_rows(path, "plans")
        assert plans and all(plan["status"] != "policy" for plan in plans)
        assert any(
            "shared_resource_binding_unproved" in gap["reason"]
            for gap in plans[0]["gaps"]
        )
        return {"trace": commands, "root_gaps": plans[0]["gaps"]}
    assert learned["state"] == "WIN" and learned["goal"] == "observed"
    first, second = decisions
    assert first["policy"]["operation"] == "freeze_observed_goal_policy", first
    assert second["reason"] == "revalidated_goal_policy"
    plan = load(path, first["policy"]["artifact"])
    outgoing = {
        edge["action"][0]: edge for edge in plan["edges"] if edge["before"] == 1
    }
    assert {1, 2} <= outgoing.keys(), outgoing
    for action in (1, 2):
        budget = {
            key: value
            for key, value in outgoing[action]["expected"].items()
            if key.startswith("count-")
        }
        assert budget == {"count-1": 0}
    assert commands == [2, 2]
    assert not projected_path_exists(plan, outgoing[1]["after"])
    assert projected_path_exists(plan, outgoing[2]["after"])
    assert all(set(row["assessments"].values()) == {"supported"} for row in checks)
    assert checks[-1]["policy"]["feedback"] == "achieved"
    assert any(
        "shared_resource_binding_unproved" in gap["reason"] for gap in plan["gaps"]
    )
    return {"trace": commands, "first_edges": outgoing, "root_gaps": plan["gaps"]}


def main(config, run):
    root = Path.cwd()
    runtime = runtime_paths(root)
    task = read_task(config)
    plan = read_plan(task["judge_config"])
    table = {s.variant: s for s in scenes(plan, plan["training_seeds"][0])}
    resource_case = task["kind"] == "resource_composition"
    training, targets, goal = (
        shared_token(table) if resource_case else switch_circuit(table)
    )
    games = run / "private/games"
    materialize(
        games,
        list(
            {s.public_id: s for s in (*targets, *(row[0] for row in training))}.values()
        ),
    )
    reports = {}
    if resource_case:
        reachable_after_wrong_turn(targets[0])
    for scene in targets:
        reachable = list(reference.reachable(scene))
        if scene.variant != "offscreen-switch":
            assert any(reference.goal_reached(scene, state) for state in reachable) == (
                scene == targets[0]
            )
        reports[scene.variant] = finite_engine_check(scene)
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        run / "private/server",
        run / "grade/environment.log",
    ) as (url, _):
        for scene in targets:
            _, trace = http_trace(url, scene)
            write_json(run / "private" / (scene.variant + "-oracle.json"), trace)
        roster = run / "public/training"
        collect_training(root, runtime, url, roster, training)
        for index, scene in enumerate(targets):
            path = run / "public" / scene.variant
            path.mkdir()
            agent = path / "agent.toml"
            online_config(agent, root, url, scene, budget=5, prior=roster, goal=goal)
            assert supervise(root, agent, path) == 0, (path / "solver.log").read_text()
            audit = audit_resource if resource_case else audit_switch
            reports[scene.variant]["evaluation"] = audit(
                path, scene, positive=index == 0
            )
    case = targets[0].case
    write_json(run / f"public/{case}.json", reports)
    append_assertion(
        run,
        case,
        True,
        [f"public/{case}.json", *(f"public/{s.variant}/checks" for s in targets)],
    )


if __name__ == "__main__":
    main(*(Path(arg) for arg in sys.argv[1:]))
