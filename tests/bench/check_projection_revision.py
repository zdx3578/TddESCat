"""Verify revised frame contracts using isolated SDK receipts in both contexts."""

from dataclasses import replace
from pathlib import Path
import sys

from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_tools.isolation import environment_server
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_composition import collect_training
from tests.bench.check_evidence import solver_process
from tests.bench.check_online import online_config, load
from tests.bench.check_sequence_learning import check_scene


def main(config, run):
    root = Path.cwd()
    runtime = runtime_paths(root)
    task = read_task(config)
    plan = read_plan(task["judge_config"])
    base = next(
        s for s in scenes(plan, plan["training_seeds"][0]) if s.variant == "open-square"
    )
    used = {base.background, base.letterbox, *(cell[2] for cell in base.bodies[0])}
    peer_ink = max(set(range(16)) - used)
    width, height = base.logical_size

    def scene(i, moves_peer, x):
        return replace(
            base,
            public_id=base.public_id + f"PR{i:02}",
            active=(1, 1, width - 1, height - 1),
            static=(),
            blocked=(),
            holes=(),
            start=((x, 6), (16 if moves_peer else 19, 3)),
            bodies=(base.bodies[0], ((0, 0, peer_ink),)),
            moves=((1, 0, -1), (2, 0, 1)),
            dynamics="autonomous" if moves_peer else "static",
        )

    earlier = [scene(i, i % 2 == 1, x) for i, x in enumerate((3, 5, 7, 9))]
    held = [scene(4, True, 11), scene(5, False, 13)]
    public = run / "public"
    train = public / "training"
    games = run / "private/games"
    materialize(games, [*earlier, *held])
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
            train,
            [(s, 2) for s in earlier],
            interventions={s.public_id: [1] for s in earlier},
        )
        probes = []
        for i, s in enumerate(held):
            output = public / f"held-{i}"
            output.mkdir()
            config = output / "agent.toml"
            online_config(config, root, url, s, collection=True, budget=2)
            probes.append(dict(config=str(config), output=str(output)))
        request = public / "requests.json"
        result_file = public / "projection-revision.json"
        write_json(
            request,
            dict(
                earlier=[str(p) for p in sorted(train.glob("episode-*"))],
                probes=probes,
                output=str(result_file),
            ),
        )
        result = solver_process(
            root,
            runtime,
            public,
            str(request),
            script=root / "tests/julia/projection_public.jl",
            extra_read=(root / "config/stitch.toml",),
        )
        (run / "grade/projection.log").write_text(result.stdout + result.stderr)
        assert result.returncode == 0, result.stderr
    result = load(public, result_file.name)
    for i, s in enumerate(held):
        events = check_scene(public / f"held-{i}", s)
        assert [entry["action"]["id"] for entry in events] == [0, 1]
        output = result["outputs"][i]
        assert (
            output["ref"] == events[-1]["event_id"] and output["feedback"]["matching"]
        )
        assert output["claim"]["status"] == "conditioned_projection"
    assert (
        result["outputs"][0]["claim"]["base_sha256"]
        != result["outputs"][0]["claim"]["projected_sha256"]
    )
    assert (
        result["outputs"][1]["claim"]["base_sha256"]
        == result["outputs"][1]["claim"]["projected_sha256"]
    )
    append_assertion(
        run, "public_projection_revision", True, ["public/projection-revision.json"]
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
