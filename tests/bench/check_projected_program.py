"""Check a published two-step program that needs visible corrected projections."""

from copy import deepcopy
from dataclasses import replace
from hashlib import sha256
from pathlib import Path
import sys

from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import process_jobs
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tddesc_tools.stitch import build_identity

from tests.bench.check_composition import collect_training
from tests.bench.check_evidence import solver_process
from tests.bench.check_online import load, online_config
from tests.bench.measurement_audit import receipts
from tests.bench.projection_audit import ProjectionAuditor
from tests.bench.program_audit import frame_sha


def fixture(base, serial, x, *, moves_peer=False, peer=True):
    used = {base.background, base.letterbox, *(cell[2] for cell in base.bodies[0])}
    peer_ink = max(set(range(16)) - used)
    width, height = base.logical_size
    return replace(
        base,
        public_id=base.public_id + f"QP{serial:02}",
        active=(1, 1, width - 1, height - 1),
        static=(),
        blocked=(),
        holes=(),
        start=((x, 6), (x + (8 if moves_peer else 11), 3)) if peer else ((x, 6),),
        bodies=(base.bodies[0], ((0, 0, peer_ink),)) if peer else (base.bodies[0],),
        moves=((1, 0, -1), (2, 0, 1)),
        dynamics="autonomous" if moves_peer else "static",
    )


def audit_projection(public, report, scope):
    audit = ProjectionAuditor([1, 2, 4])
    prior = {}
    for path in [*scope, public / "held"]:
        history = [0]
        trace = receipts(path)
        for event, after in trace.values():
            action = event["action"]["id"]
            if action:
                prior[event["event_id"]] = (
                    trace[event["before_ref"]][1],
                    event,
                    history[:],
                    {},
                )
                history.append(action)
    for row in report["learned"]:
        audit.check(row["claim"], row["feedback"], *prior[row["event"]])
    held = receipts(public / "held")
    for row in report["actual"]["rows"]:
        observed = held[row["event"]][1]
        assert row["claim"]["projected_sha256"] == frame_sha(observed["frame"][-1])
        assert row["claim"]["base_sha256"] != row["claim"]["projected_sha256"]
        deepcopy(audit).check(row["claim"], row["feedback"], *prior[row["event"]])
        for field, value, expected in (
            ("condition_reads", [], "projection_complete_condition_reads"),
            ("anchor", [0, 0], "projection_anchor_binding"),
        ):
            mutated = {**row["claim"], field: value}
            try:
                deepcopy(audit).check(mutated, row["feedback"], *prior[row["event"]])
            except ValueError as error:
                assert str(error) == expected, error
            else:
                raise AssertionError(f"Projection audit accepted the changed {field}")
    assert [row["status"] for row in report["actual"]["rows"]] == [
        "advance",
        "completed",
    ]


def main(config, run):
    root = Path.cwd()
    runtime, task = runtime_paths(root), read_task(config)
    plan = read_plan(task["judge_config"])
    base = next(
        s for s in scenes(plan, plan["training_seeds"][0]) if s.variant == "open-square"
    )
    training = [fixture(base, i, 3 + i % 8, peer=False) for i in range(12)]
    scope = [
        fixture(base, 20 + i, x, moves_peer=i % 2 == 1)
        for i, x in enumerate(range(3, 9))
    ]
    held = fixture(base, 30, 11, moves_peer=True)
    games, public = run / "private/games", run / "public"
    materialize(games, [*training, *scope, held])
    policy = root / "config/stitch.toml"
    worker = root / "target/release/tddesc-stitch"
    identity, policy_sha = (
        build_identity(root, worker),
        sha256(policy.read_bytes()).hexdigest(),
    )
    write_json(
        public / "supervision.json",
        dict(policy_sha256=policy_sha, engine_identity=identity),
    )
    script = root / "tests/julia/projected_program_public.jl"

    def julia(mode):
        result = solver_process(
            root,
            runtime,
            public,
            mode,
            str(public),
            script=script,
            timeout=290,
            extra_read=(
                policy,
                root / "Cargo.lock",
                root / "rust-toolchain.toml",
                root / "third_party/egg-stitch/UPSTREAM.toml",
            ),
        )
        (run / f"grade/{mode}.log").write_text(result.stdout + result.stderr)
        assert result.returncode == 0, result.stderr

    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        run / "private/server",
        run / "grade/environment.log",
    ) as (url, _):
        for directory, group in (("training", training), ("scope", scope)):
            collect_training(
                root,
                runtime,
                url,
                public / directory,
                [(s, 3) for s in group],
                interventions={s.public_id: [1, 1] for s in group},
            )
        test = public / "held"
        test.mkdir()
        agent = test / "agent.toml"
        online_config(agent, root, url, held, collection=True, budget=3)
        scope_paths = sorted((public / "scope").glob("episode-*"))
        write_json(
            public / "projected-program-inputs.json",
            dict(
                config=str(agent),
                held=str(test),
                scope=[str(path) for path in scope_paths],
                training=[
                    str(path)
                    for path in sorted((public / "training").glob("episode-*"))
                ],
            ),
        )
        julia("prepare")
        process_jobs(
            root,
            public,
            worker,
            identity["binary_sha256"],
            policy_sha,
            6 * 1024**3,
            None,
            set(),
        )
        julia("verify")
    audit_projection(public, load(public, "projected-program.json"), scope_paths)
    append_assertion(
        run, "conditioned_projection_program", True, ["public/projected-program.json"]
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
