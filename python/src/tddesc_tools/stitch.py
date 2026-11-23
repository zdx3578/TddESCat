"""Run the frozen E-Stitch worker with a finite Linux resource limit."""

import argparse
import hashlib
import json
import shutil
import subprocess
import tomllib
from pathlib import Path

from .contracts import Contracts
from .isolation import sandbox


def run_worker(root, job, output, binary):
    manifest_file = job / "manifest.json"
    manifest = json.loads(manifest_file.read_bytes())
    contracts = Contracts(root / "protocol/v1")
    contracts.validate("learn_job", manifest)
    config_file = manifest["config_file"]
    config_path = (job / config_file["path"]).resolve(strict=True)
    if not config_path.is_relative_to(job):
        raise ValueError("Frozen worker config path escaped job")
    config_data = config_path.read_bytes()
    if (
        len(config_data) != config_file["bytes"]
        or hashlib.sha256(config_data).hexdigest() != config_file["sha256"]
    ):
        raise ValueError("Frozen worker config hash differs")
    budget = tomllib.loads(config_data.decode())["budget"]
    wall_ms, memory = budget["wall_ms"], budget["managed_bytes"]
    if type(wall_ms) is not int or not 1 <= wall_ms <= 600_000:
        raise ValueError("Worker deadline is outside the supported range")
    if type(memory) is not int or not 1 <= memory <= 1_073_741_824:
        raise ValueError("Worker memory is outside the supported range")
    controller = shutil.which("systemd-run")
    if controller is None or not Path("/sys/fs/cgroup/cgroup.controllers").is_file():
        raise RuntimeError("The worker requires a cgroup v2 systemd user manager")
    if output.exists():
        raise ValueError("Worker output directory already exists")
    output.mkdir(parents=True)
    command = [
        controller,
        "--user",
        "--quiet",
        "--wait",
        "--pipe",
        "--collect",
        "-p",
        f"MemoryMax={memory}",
        "-p",
        "MemorySwapMax=0",
        "-p",
        f"RuntimeMaxSec={wall_ms + 2000}ms",
        "-p",
        "TasksMax=16",
        "-p",
        "NoNewPrivileges=yes",
        "--",
        *sandbox(
            [str(binary), "--manifest", str(manifest_file), "--output", str(output)],
            read=(binary, job),
            write=(output,),
            offline=True,
        ),
    ]
    log = output.with_name(output.name + ".worker.log")
    with log.open("xb") as stream:
        try:
            result = subprocess.run(
                command,
                stdout=stream,
                stderr=subprocess.STDOUT,
                timeout=wall_ms / 1000 + 10,
            )
            exit_code = result.returncode
        except subprocess.TimeoutExpired:
            exit_code = 23
    if exit_code not in (0, 10, 20, 21, 22):
        exit_code = 23
    for folder in sorted(output.glob("round-*")):
        if folder.name.endswith(".tmp"):
            continue
        contracts.validate(
            "learn_result", json.loads((folder / "result.json").read_bytes())
        )
    return exit_code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--job", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    return run_worker(
        root, args.job.resolve(), args.output.resolve(), args.binary.resolve()
    )


if __name__ == "__main__":
    raise SystemExit(main())
