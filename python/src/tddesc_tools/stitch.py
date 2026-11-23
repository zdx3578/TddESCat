"""Run the frozen E-Stitch worker with a finite Linux resource limit."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tomllib
from pathlib import Path

from .contracts import Contracts
from .isolation import sandbox


def build_identity(root, binary):
    result = subprocess.run(
        [str(binary), "--identity"],
        check=True,
        capture_output=True,
        text=True,
        timeout=8,
    )
    pin = json.loads(result.stdout)
    files = [
        root / name
        for name in (
            "Cargo.toml",
            "Cargo.lock",
            "rust-toolchain.toml",
            "rust/bridge/Cargo.toml",
            "rust/bridge/build.rs",
            "third_party/egg-stitch/Cargo.toml",
            "third_party/egg/Cargo.toml",
        )
    ]
    for directory in (
        "rust/bridge/src",
        "third_party/egg-stitch/src",
        "third_party/egg/src",
    ):
        files.extend(path for path in (root / directory).rglob("*") if path.is_file())
    digest = hashlib.sha256()
    for path in sorted(files):
        digest.update(path.relative_to(root).as_posix().encode() + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    with binary.open("rb") as stream:
        built = hashlib.file_digest(stream, "sha256").hexdigest()
    if pin != {"build_sha256": digest.hexdigest(), "binary_sha256": built}:
        raise ValueError("Configured worker was built from different local sources")
    return pin


def run_worker(root, job, output, binary, *, hard_memory=None):
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
    hard_memory = memory if hard_memory is None else hard_memory
    if type(hard_memory) is not int or hard_memory <= 0:
        raise ValueError("Worker hard memory cap must be positive")
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
        f"MemoryMax={hard_memory}",
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
            [
                "/usr/bin/time",
                "-v",
                str(binary),
                "--manifest",
                str(manifest_file),
                "--output",
                str(output),
            ],
            read=(binary, job),
            write=(output,),
            offline=True,
        ),
    ]
    log = output.with_name(output.name + ".worker.log")
    environment = os.environ.copy()
    environment.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    with log.open("xb") as stream:
        try:
            result = subprocess.run(
                command,
                stdout=stream,
                stderr=subprocess.STDOUT,
                timeout=wall_ms / 1000 + 10,
                env=environment,
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
    parser.add_argument("--hard-memory", type=int)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    return run_worker(
        root,
        args.job.resolve(),
        args.output.resolve(),
        args.binary.resolve(),
        hard_memory=args.hard_memory,
    )


if __name__ == "__main__":
    raise SystemExit(main())
