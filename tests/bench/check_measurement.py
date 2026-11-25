"""Discover and consume a strip measurement from stationary public actions."""

import sys
from dataclasses import replace
from pathlib import Path

from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_env.bench.scenario import Resource
from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import supervise
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_core_learning import captured_rows
from tests.bench.check_online import load, online_config
from tests.bench.check_sequence_learning import check_scene
from tests.bench.measurement_audit import receipts, replay_meters, verify_step


def display_scene(base, *, width=14, start=(2, 2), suffix="T01"):
    used = {base.background, base.letterbox}
    used.update(color for body in base.bodies for _, _, color in body)
    fill, rim = sorted(set(range(16)) - used)[:2]
    x, y = start
    border = [
        (u, v, rim)
        for v in range(y - 1, y + 2)
        for u in range(x - 1, x + width + 1)
        if v != y or u in (x - 1, x + width)
    ]
    return replace(
        base,
        public_id=base.public_id + suffix,
        start=((7, 8),),
        moves=(),
        static=tuple(border),
        blocked=(),
        holes=(),
        resource=Resource(start, (), fill, width, display_spacing=1),
    )


def main(config, run):
    root = Path.cwd()
    task = read_task(config)
    runtime = runtime_paths(root)
    plan = read_plan(task["judge_config"])
    base = next(
        s for s in scenes(plan, plan["training_seeds"][0]) if s.variant == "open-square"
    )
    scene = display_scene(base)
    games = run / "private/games"
    materialize(games, [scene])
    public = run / "public"
    path = public / "episode"
    path.mkdir()
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        run / "private/server",
        run / "grade/environment.log",
    ) as (url, _):
        cfg = path / "agent.toml"
        online_config(cfg, root, url, scene, budget=15, batch=6)
        assert supervise(root, cfg, path) == 0, (path / "solver.log").read_text()
    events = check_scene(path, scene)
    raw = receipts(path)
    measurements = replay_meters(raw)
    supported = []
    for row in captured_rows(path, "checks"):
        data = row["evidence"]
        ref = row["event_ref"]
        verify_step(data, measurements[ref])
        assert not data["residual"]
        assert {effect["family"] for effect in data["effects"]} == {"measurement"}
        if row["assessments"]:
            assert set(row["assessments"].values()) == {"supported"}
            assert all(key.startswith("measurement-") for key in row["assessments"])
            assert all(
                raw[read][0]["sequence"] < raw[ref][0]["sequence"]
                for read in row["read_events"]
            )
            supported.append(ref)
    assert len(events) == 15 and len(measurements) == 14
    assert supported
    durable = [
        ref
        for ref in load(path, "public-run.json")["learned"]["publications"]
        if "display_shift" in str(load(path, f"publication/{ref}.json")["library"])
    ]
    assert durable
    write_json(
        public / "measurement.json", dict(supported=supported, publications=durable)
    )
    append_assertion(
        run, "measurement_public_feedback", True, ["public/measurement.json"]
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
