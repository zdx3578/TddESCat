"""Run an isolated E-Stitch worker against its frozen learning policy."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tomllib
from pathlib import Path
from time import sleep
from uuid import uuid4

from .contracts import Contracts
from .isolation import sandbox
from .run import write_json

LEARNING_PROTOCOL = "tddescat.learn.v2"
TEST_FAULTS = (
    "before-first-commit",
    "after-first-commit",
    "during-first-write",
    "resource-load",
)


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
            "third_party/egg-stitch/UPSTREAM.toml",
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


def effective_memory(unit, environment):
    try:
        result = subprocess.run(
            ["systemctl", "--user", "show", "--property=ControlGroup", "--value", unit],
            capture_output=True,
            check=False,
            text=True,
            env=environment,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None, False
    control = result.stdout.strip()
    if result.returncode or not control.startswith("/"):
        return None, False
    root = Path("/sys/fs/cgroup")
    group = root / control.lstrip("/")
    limits = []
    for directory in (group, *group.parents):
        if not directory.is_relative_to(root):
            break
        try:
            value = (directory / "memory.max").read_text().strip()
        except FileNotFoundError:
            continue
        if value != "max":
            limits.append(int(value))
    return min(limits, default=None), group.is_dir()


def run_worker(
    root,
    job,
    output,
    binary,
    *,
    hard_memory=None,
    expected_policy=None,
    solver_unit=None,
    test_fault=None,
):
    manifest_file = job / "manifest.json"
    manifest = json.loads(manifest_file.read_bytes())
    contracts = Contracts(root / "protocol")
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
    policy = tomllib.loads(config_data.decode())
    policy_sha = config_file["sha256"]
    if policy.get("schema_version") != 2 or ("budget" in policy):
        raise ValueError("Expected the schema 2 learning policy")
    if expected_policy is not None and policy_sha != expected_policy:
        raise ValueError("Frozen policy differs from the supervised session")
    if hard_memory is not None and (type(hard_memory) is not int or hard_memory <= 0):
        raise ValueError("Invalid declared worker hard memory limit")
    controller = shutil.which("systemd-run")
    if controller is None or not Path("/sys/fs/cgroup/cgroup.controllers").is_file():
        raise RuntimeError("The worker requires a cgroup v2 systemd user manager")
    if output.exists():
        raise ValueError("Worker output directory already exists")
    output.mkdir(parents=True)
    unit = f"tddesc-stitch-{uuid4().hex}.service"
    properties = ["-p", "MemorySwapMax=0", "-p", "NoNewPrivileges=yes"]
    if hard_memory is not None:
        properties.extend(["-p", f"MemoryMax={hard_memory}"])
    if solver_unit is not None:
        properties.extend(
            ["-p", f"BindsTo={solver_unit}", "-p", f"After={solver_unit}"]
        )
    command = [
        controller,
        "--user",
        "--quiet",
        "--wait",
        "--pipe",
        "--collect",
        "--unit",
        unit,
        *properties,
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
                *(["--test-fault", test_fault] if test_fault is not None else []),
            ],
            read=(binary, job),
            write=(output,),
            offline=True,
        ),
    ]
    log = output.with_name(output.name + ".worker.log")
    environment = os.environ.copy()
    environment.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    resource_limit, observed = None, False
    with log.open("xb") as stream:
        with subprocess.Popen(
            command, stdout=stream, stderr=subprocess.STDOUT, env=environment
        ) as worker:
            try:
                for _ in range(8):
                    resource_limit, observed = effective_memory(unit, environment)
                    if observed or worker.poll() is not None:
                        break
                    sleep(0.02)
                exit_code = worker.wait()
            finally:
                if worker.poll() is None:
                    subprocess.run(
                        ["systemctl", "--user", "stop", unit],
                        check=False,
                        env=environment,
                    )
    write_json(
        output / "worker-policy.json",
        {
            "policy_sha256": policy_sha,
            "schema_version": 2,
            "explicit_memory_bytes": hard_memory,
            "observed_cgroup_memory_bytes": resource_limit,
            "cgroup_observed": observed,
            "host_memory_bytes": os.sysconf("SC_PAGE_SIZE")
            * os.sysconf("SC_PHYS_PAGES"),
            "runtime_deadline": None,
            "unit": unit,
        },
    )
    if exit_code not in (0, 10, 20, 21, 22):
        exit_code = 23
    for folder in sorted(output.glob("round-*")):
        if folder.name.endswith(".tmp"):
            continue
        contracts.validate(
            "learn_result", json.loads((folder / "result.json").read_bytes())
        )
    summary_path = output / "learning-summary.json"
    if summary_path.is_file():
        summary = json.loads(summary_path.read_bytes())
        contracts.validate("learn_summary", summary)
        if exit_code in (0, 10) and summary["scope_refs"]["policy"] != policy_sha:
            raise ValueError("Worker summary has a different frozen policy")
    elif exit_code in (0, 10):
        return 23
    return exit_code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--job", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--hard-memory", type=int)
    parser.add_argument("--test-fault", choices=TEST_FAULTS, help=argparse.SUPPRESS)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    return run_worker(
        root,
        args.job.resolve(),
        args.output.resolve(),
        args.binary.resolve(),
        hard_memory=args.hard_memory,
        test_fault=args.test_fault,
    )


if __name__ == "__main__":
    raise SystemExit(main())
