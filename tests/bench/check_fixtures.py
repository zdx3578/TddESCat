"""Validate finite movement fixtures against actual official HTTP traffic."""

import json
import sys
from pathlib import Path

from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_env.bench.grade import (
    boundary_trace_checks,
    compare_repeated_traces,
    finite_engine_check,
    frame_hash,
    hand_checks,
    http_trace,
)
from tddesc_tools.isolation import environment_server, isolation_probe
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json


def main(config, run_dir):
    root = Path.cwd()
    runtime = runtime_paths(root)
    task = read_task(config)
    plan = read_plan(task["judge_config"])
    selected = [
        scenes(plan, seed)
        for group in (plan["training_seeds"], plan["development_seeds"])
        for seed in group
    ]
    selected.extend(scenes(plan, seed) for seed in plan["evaluation_seeds"])
    games = run_dir / "private" / "games"
    materialize(games, [scene for seed_group in selected for scene in seed_group])
    summary = {case: [] for case in plan["cases"]}
    hand = {}
    for seed_group in selected:
        seed = seed_group[0].seed
        hand[str(seed)] = hand_checks({scene.variant: scene for scene in seed_group})
        for scene in seed_group:
            counts = finite_engine_check(scene)
            summary[scene.case].append(
                {
                    "variant": scene.variant,
                    "seed": seed,
                    "game_id": scene.public_id,
                    **counts,
                }
            )
    write_json(run_dir / "grade" / "hand_checks.json", hand)
    write_json(run_dir / "grade" / "finite_enumeration.json", summary)
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        run_dir / "private" / "server",
        run_dir / "grade" / "environment.log",
    ) as (url, pid):
        checks = isolation_probe(
            root,
            url,
            games / selected[0][0].public_id / "scene.json",
            run_dir / "private",
            pid,
        )
        write_json(run_dir / "grade" / "isolation.json", checks)
        with (run_dir / "private" / "oracle-trace.jsonl").open(
            "w", encoding="utf-8"
        ) as ledger:
            for group in selected:
                frames = {}
                first_traces = {}
                for scene in group:
                    outputs, first = http_trace(url, scene)
                    _, second = http_trace(url, scene)
                    compare_repeated_traces(first, second)
                    frames[scene.variant] = outputs
                    first_traces[scene.variant] = first
                    for i, trace in enumerate((first, second), 1):
                        ledger.write(
                            json.dumps(
                                {
                                    "case": scene.case,
                                    "variant": scene.variant,
                                    "seed": scene.seed,
                                    "trial": i,
                                    "trace": trace,
                                },
                                separators=(",", ":"),
                            )
                            + "\n"
                        )
                    record = next(
                        row
                        for row in summary[scene.case]
                        if row["game_id"] == scene.public_id
                    )
                    record.update(
                        http_commands=sum(
                            row["path"].startswith("/api/cmd/")
                            for row in first + second
                        ),
                        frame_sha256=list(map(frame_hash, outputs)),
                    )
                assert (
                    hand_checks({scene.variant: scene for scene in group}, frames)
                    == hand[str(group[0].seed)]
                )
                boundary_trace_checks(first_traces)
    write_json(run_dir / "grade" / "fixture_summary.json", summary)
    for case, results in summary.items():
        assert results and all(x["http_commands"] >= 4 for x in results)
        append_assertion(
            run_dir,
            case,
            True,
            [
                "grade/hand_checks.json",
                "grade/fixture_summary.json",
                "grade/isolation.json",
                "private/oracle-trace.jsonl",
            ],
        )


if __name__ == "__main__":
    main(*(Path(arg) for arg in sys.argv[1:]))
