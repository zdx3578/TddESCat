"""Execute the Julia semantical checks with the pinned test toolchain."""

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


def main(config, run):
    root = Path.cwd()
    runtime = runtime_paths(root)
    kind = read_task(config)["kind"]
    scripts = {
        "semantic": ("semantic_kernel", ("semantic_kernel.jl", "guard_repair.jl")),
        "stitch": ("stitch_bridge", ("stitch_rounds.jl",)),
        "planning": ("finite_policy", ("finite_policy.jl",)),
    }
    identifier, selected = scripts[kind]
    evidence = []
    for script in selected:
        name = script.removesuffix(".jl")
        log = run / "grade" / (name + ".log")
        arguments = [str(run / "public/rust-jobs")] if kind == "stitch" else []
        command = julia_command(
            root, runtime, root / "tests/julia" / script, *arguments
        )
        with log.open("wb") as stream:
            result = subprocess.run(
                command,
                cwd=root,
                env=julia_environment(runtime),
                stdout=stream,
                stderr=subprocess.STDOUT,
            )
        evidence.append(log.relative_to(run).as_posix())
        if result.returncode:
            append_assertion(
                run, identifier, False, evidence, f"test_exit:{result.returncode}"
            )
            return 1
    append_assertion(run, identifier, True, evidence)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
