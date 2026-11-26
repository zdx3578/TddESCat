"""Re-audit an immutable confirmed capture without restarting the game."""

from hashlib import file_digest, sha256
import json
from pathlib import Path
from shutil import copy2
import sys

from tddesc_tools.contracts import Contracts
from tddesc_tools.run import write_artifact_index, write_json
from tests.bench.check_real_public import verify_autonomous_capture


def read(path):
    return json.loads(path.read_bytes())


def recheck(root, capture, output):
    capture, output = capture.resolve(), output.resolve()
    index_file = capture / "public/artifact-index.json"
    index = read(index_file)
    output.mkdir()
    generated = {
        "public/acceptance.json",
        "public/autonomous-verification.json",
        "public/replay.json",
        "public/report.md",
        "grade/assertions.jsonl",
        "grade/evidence-index.json",
        "grade/autonomous-replay.log",
    }
    seen = set()
    for entry in index["files"]:
        name = entry["path"]
        source = capture / name
        if name in seen or not source.resolve().is_relative_to(capture):
            raise ValueError(f"Invalid indexed artifact path: {name}")
        seen.add(name)
        with source.open("rb") as stream:
            fingerprint = file_digest(stream, "sha256").hexdigest()
        if fingerprint != entry["sha256"] or source.stat().st_size != entry["bytes"]:
            raise ValueError(f"Capture artifact changed: {name}")
        if name not in generated:
            target = output / name
            target.parent.mkdir(parents=True, exist_ok=True)
            copy2(source, target)
    initial = read(capture / "public/acceptance.json")
    status = read(output / "public/supervision.json")
    if "public/acceptance.json" not in seen or status["state"] != "FINISHED":
        raise ValueError(
            "The capture must have finalized its events and supervisor record"
        )
    exit_code = verify_autonomous_capture(root, output, status["code"])
    assertions = [
        json.loads(line)
        for line in (output / "grade/assertions.jsonl").read_text().splitlines()
    ]
    observed = {line["id"] for line in assertions}
    expected = {row["id"] for row in initial["tasks"]}
    if observed != expected or len(assertions) != len(observed):
        raise ValueError("Recheck must execute the capture's complete acceptance set")
    digests = {}
    for row in assertions:
        for name in row["evidence"]:
            digests[name] = sha256((output / name).read_bytes()).hexdigest()
    write_json(output / "grade/evidence-index.json", digests)
    write_json(
        output / "grade/recheck-origin.json",
        {
            "capture": str(capture),
            "indexed_files": len(seen),
            "artifact_index_sha256": sha256(index_file.read_bytes()).hexdigest(),
            "capture_acceptance_sha256": sha256(
                (capture / "public/acceptance.json").read_bytes()
            ).hexdigest(),
        },
    )
    verdict = {
        **initial,
        "run_id": output.name,
        "status": "PASS" if exit_code == 0 else "FAIL",
        "tasks": [
            {
                "id": row["id"],
                "status": row["status"],
                "reason": row["reason"],
                "assertion_refs": [
                    "grade/assertions.jsonl",
                    "grade/evidence-index.json",
                ],
            }
            for row in assertions
        ],
    }
    Contracts(root / "protocol/v1").validate("acceptance", verdict)
    write_json(output / "public/acceptance.json", verdict)
    write_artifact_index(output)
    print(verdict["status"], output, flush=True)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(recheck(Path.cwd(), *(Path(value) for value in sys.argv[1:])))
