"""Supervise the public solver and its offline learning jobs."""

import argparse
import fcntl
import json
import os
import re
import signal
import subprocess
import tempfile
import tomllib
from contextlib import contextmanager
from hashlib import sha256
from pathlib import Path
from time import monotonic, sleep
from uuid import uuid4

from .contracts import Contracts
from .isolation import solver_sandbox
from .run import julia_command, runtime_paths
from .stitch import build_identity, run_worker

BUILD_INPUTS = (
    "Cargo.lock",
    "rust-toolchain.toml",
    "third_party/egg-stitch/UPSTREAM.toml",
)
SUPERVISOR_BLOCKED = 3


def interrupted(_signal, _frame):
    raise SystemExit(143)


def atomic_json(path, payload):
    with tempfile.NamedTemporaryFile(
        mode="w", dir=path.parent, encoding="utf-8", delete=False
    ) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(payload, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(temporary, path)
            directory = os.open(path.parent, os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            temporary.unlink(missing_ok=True)


def public_settings(root, config, data, *, recovery=False):
    environment = data["environment"]
    paths = [config, *(root / name for name in BUILD_INPUTS)]
    if "learning" in data:
        policy = (config.parent / data["learning"]["policy_file"]).resolve()
        if not policy.is_file():
            raise FileNotFoundError("Configured learning policy is missing")
        paths.append(policy)
    if (name := data.get("learning", {}).get("prior_evidence")) is not None:
        previous = (config.parent / name).resolve()
        if not previous.is_dir():
            raise ValueError("Prior evidence directory is missing")
        paths.append(previous)
    if not recovery and environment.get("credentials_file"):
        credential = (config.parent / environment["credentials_file"]).resolve()
        if not credential.is_file():
            raise FileNotFoundError("Configured public ARC credential file is missing")
        paths.append(credential)
    if not recovery and not re.fullmatch(
        r"http://(?:127\.0\.0\.1|\[::1\]):[0-9]+/?", environment["base_url"]
    ):
        paths.extend(
            path
            for name in (
                "/etc/resolv.conf",
                "/etc/hosts",
                "/etc/nsswitch.conf",
                "/etc/ssl/certs",
            )
            if (path := Path(name)).exists()
        )
    return tuple(paths)


def solver_command(
    root, runtime, config, public, paths, *, command=None, recovery=False
):
    script = root / "scripts/run.jl"
    if command is None:
        command = [
            "/usr/bin/time",
            "-v",
            "-o",
            str(public / ("recovery-usage.txt" if recovery else "solver-usage.txt")),
            *julia_command(
                root,
                runtime,
                script,
                "--recover-learning" if recovery else "--supervised",
                "--config",
                str(config),
                "--public-dir",
                str(public),
            ),
        ]
    return solver_sandbox(
        root,
        runtime,
        command,
        public,
        script=script,
        extra_read=paths,
        offline=recovery,
    )


def supervisor_environment():
    return {
        "PATH": "/usr/bin:/bin",
        "LANG": "C.UTF-8",
        "XDG_RUNTIME_DIR": f"/run/user/{os.getuid()}",
    }


def process_jobs(
    root, public, binary, worker_sha, policy_sha, hard_memory, unit, serviced
):
    queue = public / "learning"
    for job in sorted(queue.glob("job-*")):
        if not re.fullmatch(r"job-\d{6,}", job.name) or job.name in serviced:
            continue
        if not (job / "input/manifest.json").is_file():
            continue
        if (job / "worker-status.json").exists() or (job / "assessment.json").exists():
            continue
        serviced.add(job.name)
        if not (
            job.is_dir()
            and job.resolve() == job
            and (job / "input").resolve() == job / "input"
        ):
            raise ValueError("Unexpected job path")
        start = monotonic()
        code, failure = 23, None
        try:
            if sha256(binary.read_bytes()).hexdigest() != worker_sha:
                raise RuntimeError("Learning executable changed during the session")
            output = job / "output"
            if output.exists():
                summary = json.loads((output / "learning-summary.json").read_bytes())
                Contracts(root / "protocol").validate("learn_summary", summary)
                if (
                    summary["scope_refs"]["binary"] != worker_sha
                    or summary["scope_refs"]["policy"] != policy_sha
                ):
                    raise ValueError(
                        "Interrupted attempt has a different worker or policy"
                    )
                code = json.loads((output / "metrics.json").read_bytes())["exit_code"]
            else:
                code = run_worker(
                    root,
                    job / "input",
                    output,
                    binary,
                    hard_memory=hard_memory,
                    expected_policy=policy_sha,
                    solver_unit=unit,
                )
        except Exception as exc:
            failure = f"{type(exc).__name__}: {exc}"
        resource = job / "output/worker-policy.json"
        telemetry = json.loads(resource.read_bytes()) if resource.is_file() else {}
        atomic_json(
            job / "worker-status.json",
            {
                "code": code,
                "failure": failure,
                "wall_seconds": monotonic() - start,
                "binary_sha256": worker_sha,
                "policy_sha256": policy_sha,
                "hard_memory_bytes": hard_memory,
                "process_exit_code": telemetry.get("process_exit_code"),
                "termination_reason": telemetry.get("termination_reason"),
                "cgroup_memory": telemetry.get("cgroup_memory"),
            },
        )


@contextmanager
def supervisor_liveness(public, state, *, recovery):
    with (public / "supervisor.lock").open("ab" if recovery else "xb") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if recovery:
            previous = json.loads((public / "supervision.json").read_bytes())
            if any(
                previous[key] != state[key]
                for key in ("config_sha256", "engine_identity", "policy_sha256")
            ):
                raise ValueError(
                    "Recovery must use the original run configuration and worker"
                )
        atomic_json(public / "supervision.json", state)
        yield


def supervise(root, config, public, *, expected_paths=None, recovery=False):
    runtime = runtime_paths(root)
    data = tomllib.loads(config.read_text(encoding="utf-8"))
    if data["execution"]["memory_enforcement"] != "cgroup_v2":
        raise ValueError("The learning solver requests cgroup_v2 enforcement")
    binary = (config.parent / data["learning"]["engine"]).resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise RuntimeError(
            "Build the configured E-Stitch executable before running the solver"
        )
    try:
        paths = (
            public_settings(root, config, data, recovery=recovery)
            if expected_paths is None
            else expected_paths
        )
    except FileNotFoundError as exc:
        if not public.is_dir():
            public.mkdir(parents=True)
        atomic_json(
            public / "supervision.json", {"state": "BLOCKED", "reason": str(exc)}
        )
        return SUPERVISOR_BLOCKED
    if not Path("/sys/fs/cgroup/cgroup.controllers").is_file():
        raise RuntimeError("The learning solver requires cgroup v2")
    execution = data["execution"]
    solver_memory, hard_memory = (
        execution.get("solver_memory_bytes"),
        execution.get("learning_memory_bytes"),
    )
    if not all(
        value is None or (type(value) is int and value > 0)
        for value in (solver_memory, hard_memory)
    ):
        raise ValueError("Invalid hard memory cap")
    public.mkdir(parents=True, exist_ok=True)
    if recovery:
        if not (public / "learning/session.json").is_file():
            raise ValueError("No recorded learning session to recover")
    elif (public / "commands").exists() or (public / "supervision.json").exists():
        raise ValueError("A supervised session needs a fresh public directory")
    identity = build_identity(root, binary)
    worker_sha = identity["binary_sha256"]
    policy = (config.parent / data["learning"]["policy_file"]).resolve()
    policy_sha = sha256(policy.read_bytes()).hexdigest()
    unit = f"tddesc-solver-{uuid4().hex}.scope"
    state = {
        "state": "RUNNING",
        "scope": unit,
        "binary_sha256": worker_sha,
        "engine_identity": identity,
        "solver_memory_bytes": solver_memory,
        "learning_memory_bytes": hard_memory,
        "config_sha256": sha256(config.read_bytes()).hexdigest(),
        "policy_sha256": policy_sha,
        "runtime_deadline": None,
    }
    command = [
        "systemd-run",
        "--user",
        "--scope",
        "--quiet",
        "--collect",
        "--unit",
        unit,
        *(["-p", f"MemoryMax={solver_memory}"] if solver_memory is not None else []),
        "-p",
        "MemorySwapMax=0",
        "-p",
        "TasksMax=128",
        "--",
        *solver_command(root, runtime, config, public, paths, recovery=recovery),
    ]
    env = supervisor_environment()
    with (
        supervisor_liveness(public, state, recovery=recovery),
        (public / ("recovery.log" if recovery else "solver.log")).open(
            "ab" if recovery else "xb"
        ) as log,
        subprocess.Popen(
            command,
            start_new_session=True,
            stdout=log,
            stderr=subprocess.STDOUT,
            env=env,
        ) as solver,
    ):
        serviced = set()
        handler = signal.signal(signal.SIGTERM, interrupted)
        try:
            while solver.poll() is None:
                process_jobs(
                    root,
                    public,
                    binary,
                    worker_sha,
                    policy_sha,
                    hard_memory,
                    unit,
                    serviced,
                )
                sleep(0.05)
        finally:
            try:
                if solver.poll() is None:
                    subprocess.run(
                        ["systemctl", "--user", "stop", unit],
                        check=False,
                        env=env,
                        timeout=6,
                    )
            finally:
                signal.signal(signal.SIGTERM, handler)
        code = solver.wait()
        state.update(
            state="FINISHED" if code == 0 else "FAILED",
            code=code,
            jobs=sorted(
                path.parent.name
                for path in public.glob("learning/job-*/worker-status.json")
            ),
        )
        atomic_json(public / "supervision.json", state)
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--public-dir", type=Path)
    parser.add_argument("--recover-learning", action="store_true")
    args = parser.parse_args()
    if args.recover_learning and args.public_dir is None:
        parser.error("--recover-learning requires --public-dir")
    root = Path(__file__).resolve().parents[3]
    config = args.config.resolve()
    if args.public_dir is None:
        data = tomllib.loads(config.read_text(encoding="utf-8"))
        run_root = (config.parent / data["run_root"]).resolve()
        run_root.mkdir(parents=True, exist_ok=True)
        public = (
            Path(tempfile.mkdtemp(prefix=data["run_name"] + "-", dir=run_root))
            / "public"
        )
    else:
        public = args.public_dir.resolve()
    print(public, flush=True)
    return supervise(root, config, public, recovery=args.recover_learning)


if __name__ == "__main__":
    raise SystemExit(main())
