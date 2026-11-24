"""Run the pinned upstream drawing corpora through its native CLI."""

import json
import re
import subprocess
import sys
import tomllib
from hashlib import sha256
from pathlib import Path

from tddesc_tools.run import append_assertion, read_task, write_json


def main(config, run):
    root = Path.cwd()
    profile_path = read_task(config)["experiment_config"]
    reference = tomllib.loads(profile_path.read_text())["references"]
    assert reference["datasets"] == ["furniture", "wheels"]
    assert reference["num_abstractions"] == 1
    native = root / "target/release/egg-stitch"
    native_sha = sha256(native.read_bytes()).hexdigest()
    upstream = root / "third_party/egg-stitch"
    runs = {}
    evidence = []
    for dataset, expected in zip(reference["datasets"], (15, 19), strict=True):
        source = upstream / "data/domains/cogsci" / f"{dataset}.json"
        output = run / "public" / f"{dataset}.json"
        log = run / "grade" / f"{dataset}.log"
        usage = run / "grade" / f"{dataset}-usage.txt"
        command = [
            str(native),
            "--search",
            "best-first",
            "--language",
            "op-children",
            "--max-arity",
            str(reference["max_arity"]),
            "--num-abstractions",
            str(reference["num_abstractions"]),
            "--input",
            str(source),
            "--output",
            str(output),
        ]
        with log.open("wb") as stream:
            result = subprocess.run(
                ["/usr/bin/time", "-v", "-o", str(usage), *command],
                stdout=stream,
                stderr=subprocess.STDOUT,
            )
        assert result.returncode == 0, log.read_text()
        data = json.loads(output.read_bytes())
        (definition,) = data["library"]
        assert definition["arity"] == expected
        assert data["heap_sizes_at_end"] == [0]
        assert data["final_cost"] < data["cost_after_rewrites"]
        rss = re.search(
            r"Maximum resident set size \(kbytes\): (\d+)", usage.read_text()
        )
        assert rss
        runs[dataset] = {
            "command": command,
            "input_sha256": sha256(source.read_bytes()).hexdigest(),
            "actual_arity": definition["arity"],
            "expansions": definition["num_expansions"],
            "initial_cost": data["cost_after_rewrites"],
            "final_cost": data["final_cost"],
            "wall_seconds": data["elapsed_secs"],
            "maximum_rss_kib": int(rss.group(1)),
        }
        evidence.extend(
            path.relative_to(run).as_posix() for path in (output, log, usage)
        )
    write_json(
        run / "public/native-reference.json",
        {
            "engine_sha256": native_sha,
            "experiment_sha256": sha256(profile_path.read_bytes()).hexdigest(),
            "upstream": tomllib.loads((upstream / "UPSTREAM.toml").read_text())[
                "revision"
            ],
            "datasets": runs,
        },
    )
    append_assertion(
        run, "native_reference", True, ["public/native-reference.json", *evidence]
    )


if __name__ == "__main__":
    main(*(Path(value) for value in sys.argv[1:]))
