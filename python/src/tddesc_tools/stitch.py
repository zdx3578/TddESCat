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
from .isolation import limit_address_space, optional_time, sandbox, stop_native_process
from .run import clean_environment, write_json

LEARNING_PROTOCOL = "tddescat.learn.v3"
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


def worker_cgroup(unit, environment):
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
        return None, None
    control = result.stdout.strip()
    if result.returncode or not control.startswith("/"):
        return None, None
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
    return min(limits, default=None), group if group.is_dir() else None


def memory_snapshot(group):
    if group is None:
        return None
    try:
        events = (group / "memory.events").read_text().splitlines()
        counters = {key: int(value) for key, value in map(str.split, events)}
    except FileNotFoundError:
        return None
    try:
        peak = int((group / "memory.peak").read_text())
    except FileNotFoundError:
        peak = None
    return {"events": counters, "peak_bytes": peak}


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
    resume_search=None,
    pause_search_after=None,
    native_docker=False,
):
    manifest_file = job / "manifest.json"
    manifest = json.loads(manifest_file.read_bytes())
    contracts = Contracts(root / "protocol")
    contracts.validate("learn_job", manifest)

    def frozen_bytes(name):
        descriptor = manifest[f"{name}_file"]
        path = (job / descriptor["path"]).resolve(strict=True)
        if not path.is_relative_to(job):
            raise ValueError(f"Frozen worker {name} path escaped job")
        data = path.read_bytes()
        if (
            len(data) != descriptor["bytes"]
            or hashlib.sha256(data).hexdigest() != descriptor["sha256"]
        ):
            raise ValueError(f"Frozen worker {name} hash differs")
        return data

    config_data = frozen_bytes("config")
    for name in ("signature", "origins", "semantic_context"):
        contracts.validate(name, json.loads(frozen_bytes(name)))
    policy = tomllib.loads(config_data.decode())
    policy_sha = manifest["config_file"]["sha256"]
    if policy.get("schema_version") != 2 or ("budget" in policy):
        raise ValueError("Expected the schema 2 learning policy")
    if expected_policy is not None and policy_sha != expected_policy:
        raise ValueError("Frozen policy differs from the supervised session")
    if hard_memory is not None and (type(hard_memory) is not int or hard_memory <= 0):
        raise ValueError("Invalid declared worker hard memory limit")
    if output.exists():
        raise ValueError("Worker output directory already exists")
    if not native_docker and (
        shutil.which("systemd-run") is None
        or not Path("/sys/fs/cgroup/cgroup.controllers").is_file()
    ):
        raise RuntimeError("The worker requires a cgroup v2 systemd user manager")
    output.mkdir(parents=True)
    log = output.with_name(output.name + ".worker.log")
    worker_args = [
        str(binary), "--manifest", str(manifest_file), "--output", str(output),
        *(["--test-fault", test_fault] if test_fault is not None else []),
        *(["--resume-search", str(resume_search)] if resume_search else []),
        *(["--pause-search-after", str(pause_search_after)] if pause_search_after else []),
    ]
    if native_docker:
        unit = resource_limit = group = measured = ending = None
        command = [*limit_address_space(hard_memory), *optional_time(), *worker_args]
        with (
            log.open("xb") as stream,
            subprocess.Popen(
                command, stdout=stream, stderr=subprocess.STDOUT,
                start_new_session=True, env=clean_environment(),
            ) as worker,
        ):
            try:
                exit_code = worker.wait()
            finally:
                if worker.poll() is None:
                    stop_native_process(worker)
        exit_record = output / "worker-exit.txt"
        exit_record.write_text(f"{exit_code}\n", encoding="ascii")
    else:
        controller = shutil.which("systemd-run")
        unit = f"tddesc-stitch-{uuid4().hex}.service"
        properties = ["-p", "MemorySwapMax=0", "-p", "NoNewPrivileges=yes"]
        if hard_memory is not None:
            properties.extend(["-p", f"MemoryMax={hard_memory}"])
        if solver_unit is not None:
            properties.extend(
                ["-p", f"BindsTo={solver_unit}", "-p", f"After={solver_unit}"]
            )
        launcher = Path(__file__).with_name("worker_launch.sh")
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
                    "/bin/sh",
                    str(launcher),
                    str(output),
                    *worker_args,
                ],
                read=(binary, job, launcher, *((resume_search,) if resume_search else ())),
                write=(output,),
                offline=True,
            ),
        ]
        environment = os.environ.copy()
        environment.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
        resource_limit, group, measured = None, None, None
        with log.open("xb") as stream:
            with subprocess.Popen(
                command, stdout=stream, stderr=subprocess.STDOUT, env=environment
            ) as worker:
                try:
                    for _ in range(8):
                        resource_limit, group = worker_cgroup(unit, environment)
                        if group is not None or worker.poll() is not None:
                            break
                        sleep(0.02)
                    exit_record = output / "worker-exit.txt"
                    while worker.poll() is None and not exit_record.is_file():
                        measured = memory_snapshot(group) or measured
                        sleep(0.02)
                    ending = memory_snapshot(group)
                    measured = ending or measured
                    if exit_record.is_file():
                        # The launcher writes this only after waiting on the actual
                        # child. The systemd reporting client can remain blocked after
                        # the child exits, even though its output is already durable.
                        exit_code = int(exit_record.read_text(encoding="ascii").strip())
                        (output / ".supervisor-sampled").touch()
                        try:
                            worker.wait(timeout=0.3)
                        except subprocess.TimeoutExpired:
                            subprocess.run(
                                ["systemctl", "--user", "stop", "--no-block", unit],
                                check=False,
                                env=environment,
                                timeout=5,
                            )
                            worker.terminate()
                            worker.wait(timeout=5)
                    else:
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
            "cgroup_observed": group is not None,
            "cgroup_memory": measured,
            "cgroup_sample_after_exit_record": bool(ending and exit_record.is_file()),
            "process_exit_code": exit_code,
            "termination_reason": (
                "cgroup_oom_kill"
                if exit_code and measured and measured["events"].get("oom_kill", 0)
                else "worker_exit"
                if exit_code in (0, 10, 20, 21, 22)
                else "unclassified_worker_exit"
            ),
            "host_memory_bytes": os.sysconf("SC_PAGE_SIZE")
            * os.sysconf("SC_PHYS_PAGES"),
            "runtime_deadline": None,
            "unit": unit,
            **({"execution_mode": "native_docker", "memory_limit_kind": "process_address_space"} if native_docker else {}),
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
    parser.add_argument("--resume-search", type=Path)
    parser.add_argument("--pause-search-after", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    return run_worker(
        root,
        args.job.resolve(),
        args.output.resolve(),
        args.binary.resolve(),
        hard_memory=args.hard_memory,
        test_fault=args.test_fault,
        resume_search=args.resume_search.resolve() if args.resume_search else None,
        pause_search_after=args.pause_search_after,
    )


if __name__ == "__main__":
    raise SystemExit(main())
