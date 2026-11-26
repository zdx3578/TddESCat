"""Check a learned prerequisite, a public distinction, and a reopened goal."""

from dataclasses import replace
from pathlib import Path
import sys

from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_env.bench.scenario import Switch
from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import supervise
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json

from tests.bench.check_composition import collect_training
from tests.bench.check_online import load, online_config
from tests.bench.measurement_audit import receipts


def public_layouts(base):
    occupied = {base.background, base.letterbox, *(c for _, _, c in base.bodies[0])}
    marker, on, off = sorted(set(range(16)) - occupied)[-3:]
    layout = replace(
        base,
        moves=((2, 1, 0),),
        switch=Switch((18, 3), (), on, off, True),
    )
    train = []
    for label, start_on, actions in (
        ("move", False, [2, 2]),
        ("blocked", True, [2]),
        ("switchopen", True, [5, 2]),
        ("switchclosed", False, [5]),
    ):
        for i in range(8):
            train.append(
                (
                    replace(
                        layout,
                        public_id=f"{base.public_id}{label}{i:02}",
                        start=((4 + i % 5, 7 + i % 2),),
                        switch=replace(layout.switch, initial=start_on),
                    ),
                    actions,
                )
            )
    wall = tuple((10, y, marker) for y in range(5, 12))
    held = replace(
        layout, public_id=base.public_id + "RGNeeds", start=((7, 7),), static=wall
    )
    unknown = replace(
        held,
        public_id=base.public_id + "RGUnknown",
        switch=None,
        static=(*wall, (18, 9, on)),
    )
    return train, held, unknown, (base.bodies[0][0][2], marker, on)


def materialize_gate(games, layouts):
    materialize(games, layouts)
    for scene in layouts:
        file = games / scene.public_id / "fixture.py"
        with file.open("a") as src:
            src.write(
                "\n    def _shift(self, dx, dy):\n"
                "        if not self.switch_on:\n"
                "            super()._shift(dx, dy)\n"
            )


def capture(root, url, scene, public, prior, goal, *, enabled):
    public.mkdir()
    config = public / "agent.toml"
    online_config(
        config, root, url, scene, prior=prior, goal=goal, sequences=True, budget=7
    )
    if enabled:
        config.write_text(
            config.read_text().replace(
                "[planning]", "[planning]\nrelation_goals = true"
            )
        )
    code = supervise(root, config, public)
    assert code == 0, (public / "solver.log").read_text()
    trace = receipts(public)
    rows = []
    for event, reply in trace.values():
        if event["action"]["id"]:
            file = event["command_ref"] + ".json"
            decision = load(public / "decisions", file)
            check = load(public / "checks", file)
            assert event["action"] == decision["action"] == check["action"]
            rows.append((event, reply, decision, check))
    model = load(public, "public-run.json")["learned"]
    assert model["frozen_before"] == model["frozen_after"]
    return rows, model, next(iter(trace.values()))[1]


def main(config, run):
    root = Path.cwd()
    runtime = runtime_paths(root)
    task = read_task(config)
    plan = read_plan(task["judge_config"])
    base = next(
        s for s in scenes(plan, plan["training_seeds"][0]) if s.variant == "open-square"
    )
    training, held, unknown, goal = public_layouts(base)
    games, public = run / "private/games", run / "public"
    prior = public / "previous"
    materialize_gate(games, [*(scene for scene, _ in training), held, unknown])
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
            [(scene, len(actions) + 1) for scene, actions in training],
            interventions={scene.public_id: actions for scene, actions in training},
        )
        rows, model, initial = capture(
            root, url, held, public / "held", prior, goal, enabled=True
        )
        baseline, base_model, base_initial = capture(
            root,
            url,
            held,
            public / "baseline",
            prior,
            goal,
            enabled=False,
        )
        probe, _, _ = capture(
            root, url, unknown, public / "unknown", prior, goal, enabled=True
        )
    assert initial["frame"] == base_initial["frame"]
    assert model["frozen_before"] == base_model["frozen_before"]
    assert model["goal"] == "observed"
    program = next(
        row[3]["program"]
        for row in rows
        if row[3].get("program")
        and row[3]["program"].get("goal", {}).get("regression", {}).get("producer")
    )
    assert program["definition"] and program["relation_contract"]["source_events"]
    assert program["goal"]["regression"]["producer"]["conditions"]
    assert "cue_visible" in program["goal"]["regression"]["reopened"]
    # Verify the switch's observed public effect, independently of the model's verdict.
    cue = goal[2]
    visible = [
        any(cue in line for line in response["frame"][-1]) for _, response, _, _ in rows
    ]
    assert any(cue in line for line in initial["frame"][-1])
    assert visible[-1] and not all(visible)
    experiment = next(
        row for row in probe if row[2]["reason"] == "discriminate_goal_relation"
    )
    assert experiment[2]["policy"]["predictions"]
    assert experiment[1]["frame"] and experiment[0]["completion"] == "confirmed"
    evidence = {
        "program": program,
        "baseline": [row[0]["action"] for row in baseline],
        "actual": [row[0]["action"] for row in rows],
        "cue_visibility_after_actions": visible,
        "experiment": {"decision": experiment[2], "feedback": experiment[3]},
    }
    write_json(public / "learned-relationships.json", evidence)
    append_assertion(
        run, "learned_relationship_tasks", True, ["public/learned-relationships.json"]
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
