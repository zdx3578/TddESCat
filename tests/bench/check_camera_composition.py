"""Check post-scroll binding, partial undo and rejected policy dependencies."""

import sys
from dataclasses import replace
from pathlib import Path

from tddesc_env.bench import reference
from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_env.bench.grade import finite_engine_check, http_trace
from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import supervise
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_composition import audit_episode, collect_training
from tests.bench.check_online import load, online_config


def screen_point(scene, state, point):
    left, top, _, _, zoom, offset_x, offset_y = reference.screen_geometry(scene, state)
    x, y = point
    return (6, offset_x + zoom * (x - left), offset_y + zoom * (y - top))


def camera_circuit(table):
    original = table["click-interior"]
    resource = table["resource-one"].resource
    base = original.bodies[0][0][2]
    used = {original.background, original.letterbox, original.selection_color, base}
    actor, token, cue, marker, ground = [
        color for color in range(16) if color not in used
    ][:5]
    target = tuple((x, y, actor) for x, y, _ in original.bodies[1])
    goal = (24, 9)
    scene = replace(
        original,
        case="C03",
        variant="scroll-and-undo",
        public_id=original.public_id + "7",
        logical_size=(40, 20),
        viewport=(0, 0, 24, 20),
        active=(16, 6, 26, 12),
        holes=tuple((x, y) for x in range(16, 26) for y in (8, 9)),
        bodies=(original.bodies[0], target),
        start=((17, 10), (23, 6)),
        static=((8, 3, ground), (13, 15, ground), (16, 4, ground), (*goal, marker)),
        moves=((1, 3, 0), (2, 0, 1), (3, -1, 0)),
        resource=replace(resource, gate_cells=((22, 6), (22, 7)), color=token),
        tracking_origin=18,
        dynamics="undo-with-token",
        signal=(17, 2, cue),
        goal=goal,
        goal_role=1,
        goal_distance=2,
        goal_with_signal=True,
    )
    before = scene.start_state
    shifted = reference.transition(scene, before, 1)
    click = screen_point(scene, shifted, shifted.positions[1])
    stale_click = screen_point(scene, before, before.positions[1])
    assert click != stale_click
    assert reference.transition(scene, shifted, stale_click).selected == 0
    chosen = reference.transition(scene, shifted, click)
    spent = reference.transition(scene, chosen, 3)
    undone = reference.transition(scene, spent, 7)
    assert chosen.selected == spent.selected == undone.selected == 1
    assert (
        undone.positions == chosen.positions and undone.resource == spent.resource == 0
    )
    assert reference.transition(scene, undone, 3).positions == undone.positions
    scene = replace(scene, prefix=(1, click, 3, 7))
    duplicate = replace(
        scene,
        variant="ambiguous-binding",
        public_id=scene.public_id + "1",
        bodies=(*scene.bodies, target),
        start=(*scene.start, scene.start[1]),
        prefix=(1, click),
    )
    assert reference.render(scene, scene.start_state) == reference.render(
        duplicate, duplicate.start_state
    )
    fixed = replace(
        scene,
        tracking_origin=None,
        viewport=(2, 0, 24, 20),
        start=shifted.positions,
        goal=None,
        goal_with_signal=False,
    )
    cropped = replace(
        scene,
        variant="unseen-target",
        public_id=scene.public_id + "5",
        viewport=(0, 0, 21, 20),
        prefix=(1,),
    )
    order = (
        replace(
            fixed,
            variant="select-before-motion",
            public_id=scene.public_id + "6",
            prefix=(click, 3),
        ),
        replace(
            fixed,
            variant="motion-before-select",
            public_id=scene.public_id + "8",
            prefix=(3, click),
        ),
    )
    terminal = []
    for control in order:
        state = control.start_state
        for action in control.prefix:
            state = reference.transition(control, state, action)
        terminal.append(state)
    assert [state.resource for state in terminal] == [0, 1]
    assert terminal[0].positions != terminal[1].positions
    choose = replace(
        fixed, public_id=scene.public_id + "2", variant="train-select", prefix=(click,)
    )
    motion = replace(
        fixed,
        public_id=scene.public_id + "3",
        variant="train-motion-history",
        initial_selection=1,
        prefix=(3, 7),
    )
    no_history = replace(
        motion,
        public_id=scene.public_id + "4",
        variant="train-no-history",
        start=spent.positions,
        resource=replace(fixed.resource, initial=0),
        prefix=(7,),
    )
    assert reference.render(motion, spent) == reference.render(
        no_history, no_history.start_state
    )
    training = [
        (s, len(s.prefix) + 1)
        for s, repeats in ((choose, 5), (motion, 4), (no_history, 3))
        for _ in range(repeats)
    ]
    proof = {
        "stale_click": stale_click,
        "new_click": click,
        "resource": [chosen.resource, spent.resource, undone.resource],
        "resource_after_action_permutations": [state.resource for state in terminal],
    }
    return training, (scene, duplicate, cropped), order, (actor, marker, cue, 1), proof


def audit_camera(path, scene, positive, proof):
    commands, decisions, checks, learned = audit_episode(path, scene)
    assert commands[0] == 1
    assert decisions[0]["policy"]["status"] == "unbound_observed_goal"
    if scene.variant == "unseen-target":
        assert commands == [1] and learned["goal"] == "unknown"
        return {"actions": commands, "goal": learned["goal"]}
    assert commands[1] == proof["new_click"]
    selected = decisions[1]["policy"]
    assert selected["operation"] == "freeze_observed_goal_policy", decisions[1]
    plan = load(path, selected["artifact"])
    assert [edge["action"][0] for edge in plan["steps"]] == [6, 3, 7]
    if positive:
        assert learned["state"] == "WIN" and learned["goal"] == "observed"
        assert commands[2:] == [3, 7]
        assert all(row["reason"] == "revalidated_goal_policy" for row in decisions[2:])
        assert all(
            set(row["assessments"].values()) == {"supported"} for row in checks[1:]
        )
        assert checks[2]["expected"]["count-1"] == 0
        assert checks[-1]["policy"]["feedback"] == "achieved"
    else:
        assert learned["state"] != "WIN"
        dispute = checks[1]
        assert list(dispute["assessments"].values()) == ["refuted"]
        assert dispute["policy"]["feedback"] == "withdrawn_after_feedback"
        revised = dispute["policy"]["invalidation"]
        assert {"binding", "relation", "condition", "pending_action"} <= {
            node.split(":")[0] for node in revised["invalidated"]
        }
        assert len(revised["retained_definitions"]) > 0
        assert len(decisions) > 2 and decisions[2]["before_ref"] == dispute["event_ref"]
        assert decisions[2]["reason"] != "revalidated_goal_policy" and commands[2] != 3
        assert not learned["publications"]
    return {
        "actions": commands,
        "plans": plan["steps"],
        "expected": [row["expected"] for row in checks],
        "policy": [row["policy"] for row in checks],
    }


def main(config, run):
    root = Path.cwd()
    runtime = runtime_paths(root)
    task = read_task(config)
    plan = read_plan(task["judge_config"])
    table = {s.variant: s for s in scenes(plan, plan["training_seeds"][0])}
    training, targets, order, goal, proof = camera_circuit(table)
    games = run / "private/games"
    materialize(
        games,
        list(
            {
                s.public_id: s
                for s in (*targets, *order, *(row[0] for row in training))
            }.values()
        ),
    )
    checked = {scene.variant: finite_engine_check(scene) for scene in targets}
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        run / "private/server",
        run / "grade/environment.log",
    ) as (url, _):
        order_images = []
        for control in order:
            frames, trace = http_trace(url, control)
            order_images.append(frames[-1])
            write_json(run / "private" / (control.variant + "-oracle.json"), trace)
        assert order_images[0] != order_images[1]
        for scene in targets:
            _, trace = http_trace(url, scene)
            write_json(run / "private" / (scene.variant + "-oracle.json"), trace)
        roster = run / "public/training"
        collect_training(
            root,
            runtime,
            url,
            roster,
            training,
            interventions={s.public_id: s.prefix for s, _ in training},
        )
        for index, scene in enumerate(targets):
            path = run / "public" / scene.variant
            path.mkdir()
            agent = path / "agent.toml"
            online_config(
                agent,
                root,
                url,
                scene,
                budget=2 if scene.variant == "unseen-target" else 6,
                batch=8,
                prior=roster,
                goal=goal,
                adapt=index == 1,
            )
            assert supervise(root, agent, path) == 0, (path / "solver.log").read_text()
            checked[scene.variant]["evaluation"] = audit_camera(
                path, scene, index == 0, proof
            )
    write_json(run / "public/C03.json", {"checks": checked, "visible_witness": proof})
    append_assertion(
        run,
        "C03",
        True,
        ["public/C03.json", *(f"public/{s.variant}/checks" for s in targets)],
    )


if __name__ == "__main__":
    main(*(Path(arg) for arg in sys.argv[1:]))
