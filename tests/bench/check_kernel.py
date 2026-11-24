"""Execute the Julia semantical checks with the pinned test toolchain."""

import os
import subprocess
import sys
from pathlib import Path

from tddesc_tools.run import (
    append_assertion,
    julia_command,
    julia_environment,
    read_task,
    runtime_paths,
)
from tests.bench.check_open_matches import check_open_matches


def main(config, run):
    root = Path.cwd()
    runtime = runtime_paths(root)
    task = read_task(config)
    kind = task["kind"]
    scripts = {
        "semantic": ("semantic_kernel", ("semantic_kernel.jl", "guard_repair.jl")),
        "stitch": ("stitch_bridge", ("stitch_rounds.jl", "stitch_open_search.jl")),
        "planning": ("finite_policy", ("finite_policy.jl",)),
    }
    identifier, selected = scripts[kind]
    evidence = []
    environment = julia_environment(runtime)
    if kind == "stitch":
        cache = run / "private/julia-depot"
        cache.mkdir(parents=True)
        environment["JULIA_DEPOT_PATH"] = (
            f"{cache}{os.pathsep}{environment['JULIA_DEPOT_PATH']}"
        )
    for script in selected:
        name = script.removesuffix(".jl")
        log = run / "grade" / (name + ".log")
        arguments = [str(run / "public/rust-jobs" / name)] if kind == "stitch" else []
        if name == "stitch_open_search":
            arguments.append(str(task["experiment_config"]))
        command = julia_command(
            root, runtime, root / "tests/julia" / script, *arguments
        )
        with log.open("wb") as stream:
            result = subprocess.run(
                command,
                cwd=root,
                env=environment,
                stdout=stream,
                stderr=subprocess.STDOUT,
            )
        evidence.append(log.relative_to(run).as_posix())
        if result.returncode:
            append_assertion(
                run, identifier, False, evidence, f"test_exit:{result.returncode}"
            )
            return 1
    if kind == "stitch":
        check_open_matches(root, runtime, run)
        evidence.extend(
            (
                "public/rust-jobs/stitch_open_search/open-structure.json",
                "public/open-matches/summary.json",
            )
        )
    append_assertion(run, identifier, True, evidence)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
