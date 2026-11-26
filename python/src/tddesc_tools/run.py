"""Run the configured verification task and retain evidence for each assertion."""

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import tomllib
from datetime import datetime, timezone
from hashlib import file_digest, sha256
from pathlib import Path
from uuid import uuid4

from .contracts import Contracts

KIND_IDS = {
    "protocol": tuple(f"P{i:02}" for i in range(1, 9)),
    "fixture": tuple(f"M{i:02}" for i in range(1, 15)),
    "evidence": ("capture_replay",),
    "motion": ("conditional_motion",),
    "online": ("M01", "M04"),
    "movement": ("M01", "M02", "M04", "M05", "M06", "M08"),
    "movement_covariance": ("M05", "M08"),
    "movement_boundaries": ("M03", "M07", "M09", "M10", "M11", "M12", "M13", "M14"),
    "semantic": ("semantic_kernel",),
    "stitch": ("stitch_bridge",),
    "stitch_reference": ("native_reference",),
    "real_public": ("public_learning_loop",),
    "arc_offline": ("public_learning_loop",),
    "autonomous_offline": ("autonomous_public_win",),
    "planning": ("finite_policy",),
    "planning_public": ("public_revalidated_policy",),
    "planning_composition": ("guard_then_joint_push", "plan_withdrawal"),
    "movement_composition": ("C01",),
    "resource_composition": ("C02",),
    "camera_composition": ("C03",),
    "association_recovery": ("A01", "A02"),
    "association_kernel": ("association_kernel",),
    "association_online": ("A04", "A05", "A06"),
    "association_revision": ("A07",),
    "association_background": ("background_learning",),
    "stitch_growth": ("stitch_growth",),
    "sequence_learning": (
        "sequence_discovery",
        "sequence_consumption",
        "sequence_withdrawal",
        "sequence_resource",
        "sequence_click",
        "sequence_live",
    ),
    "sequence_depth": ("eight_step_program",),
    "trace_learning": ("learned_intermediate_response",),
    "measurement_learning": ("measurement_public_feedback",),
    "measurement_goal": ("measurement_goal_execution", "program_publication_recovery"),
    "projection_revision": ("public_projection_revision",),
    "projected_program": ("conditioned_projection_program",),
    "relation_goal": ("relation_goal_producer",),
    "learned_relationships": ("learned_relationship_tasks",),
    "learned_policy": ("published_policy_withheld_instances",),
    "object_interventions": ("object_intervention_advancement",),
}
MODULES = {
    "protocol": "tests.protocol.test_faults",
    "fixture": "tests.bench.check_fixtures",
    "evidence": "tests.bench.check_evidence",
    "motion": "tests.bench.check_motion",
    "online": "tests.bench.check_online",
    "movement": "tests.bench.check_core_learning",
    "movement_covariance": "tests.bench.check_core_learning",
    "movement_boundaries": "tests.bench.check_boundaries",
    "semantic": "tests.bench.check_kernel",
    "stitch": "tests.bench.check_kernel",
    "stitch_reference": "tests.bench.check_stitch_reference",
    "real_public": "tests.bench.check_real_public",
    "arc_offline": "tests.bench.check_real_public",
    "autonomous_offline": "tests.bench.check_real_public",
    "arc_public25": "tests.bench.check_public25",
    "planning": "tests.bench.check_kernel",
    "planning_public": "tests.bench.check_core_learning",
    "planning_composition": "tests.bench.check_core_learning",
    "movement_composition": "tests.bench.check_composition",
    "resource_composition": "tests.bench.check_composition",
    "camera_composition": "tests.bench.check_camera_composition",
    "association_recovery": "tests.bench.check_association_recovery",
    "association_kernel": "tests.bench.check_kernel",
    "association_online": "tests.bench.check_association",
    "association_revision": "tests.bench.check_association_revision",
    "association_background": "tests.bench.check_association_background",
    "sequence_learning": "tests.bench.check_sequence_learning",
    "sequence_depth": "tests.bench.check_sequence_depth",
    "trace_learning": "tests.bench.check_trace_learning",
    "measurement_learning": "tests.bench.check_measurement",
    "measurement_goal": "tests.bench.check_meter_goal",
    "projection_revision": "tests.bench.check_projection_revision",
    "projected_program": "tests.bench.check_projected_program",
    "relation_goal": "tests.bench.check_relation_goal",
    "learned_relationships": "tests.bench.check_learned_relation_goals",
    "learned_policy": "tests.bench.check_learned_policy",
    "object_interventions": "tests.bench.check_object_interventions",
    "stitch_growth": "tests.bench.check_kernel",
}


def now():
    return datetime.now(timezone.utc).isoformat()


def write_artifact_index(run_dir):
    """Index the exact public receipts and verification files of a run."""
    entries = []
    index = run_dir / "public/artifact-index.json"
    for folder in ("public", "grade"):
        for path in sorted((run_dir / folder).rglob("*")):
            if path == index or not path.is_file() or path.is_symlink():
                continue
            relative = path.relative_to(run_dir)
            if any(
                part.startswith(".") or part.endswith(".lock")
                for part in relative.parts
            ):
                continue
            if not path.resolve().is_relative_to(run_dir.resolve()):
                raise ValueError(f"Artifact path escapes its run directory: {relative}")
            with path.open("rb") as stream:
                entries.append(
                    {
                        "path": relative.as_posix(),
                        "bytes": path.stat().st_size,
                        "sha256": file_digest(stream, "sha256").hexdigest(),
                    }
                )
    write_json(index, {"schema_version": 1, "files": entries})


def read_task(path):
    path = path.resolve()
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    common = {"schema_version", "kind", "output_name"}
    paths = {"agent_config", "environment_config", "judge_config"}
    kind = data.get("kind")
    required = common.copy()
    if kind in ("arc_offline", "autonomous_offline", "arc_public25"):
        required.add("offline_bundle")
    if kind == "arc_public25":
        required.update(("game_ids", "environment_config", "actions_per_game"))
    if kind == "learned_policy":
        required.update(("training_evidence", "training_cutoff"))
    if kind in ("stitch", "stitch_reference", "sequence_depth"):
        required.add("experiment_config")
        paths.add("experiment_config")
    if not required <= data.keys() or data.keys() - required - paths - {
        "timeout_seconds"
    }:
        raise ValueError(f"Invalid acceptance configuration keys: {path}")
    if type(data["schema_version"]) is not int or data["schema_version"] != 1:
        raise ValueError("Unsupported acceptance configuration version")
    if not isinstance(data["output_name"], str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9_.-]*", data["output_name"]
    ):
        raise ValueError("Invalid output_name")
    if "timeout_seconds" in data:
        if type(data["timeout_seconds"]) is not int or data["timeout_seconds"] <= 0:
            raise ValueError("Invalid timeout_seconds")
    for field in data.keys() & paths:
        value = data[field]
        if not isinstance(value, str) or not value:
            raise ValueError(f"Invalid {field}")
        data[field] = (path.parent / value).resolve()
        if not data[field].is_file():
            raise ValueError(f"Missing {field}: {data[field]}")
    if kind in ("arc_offline", "autonomous_offline", "arc_public25"):
        if not isinstance(data["offline_bundle"], str) or not data["offline_bundle"]:
            raise ValueError("Invalid offline_bundle")
        data["offline_bundle"] = (path.parent / data["offline_bundle"]).resolve()
    if kind == "learned_policy":
        data["training_evidence"] = (path.parent / data["training_evidence"]).resolve()
        if not data["training_evidence"].is_dir() or not re.fullmatch(
            r"c[0-9]{9}", data["training_cutoff"]
        ):
            raise ValueError(
                "Expected public training evidence and a confirmed command cutoff"
            )
    if kind == "arc_public25":
        if type(data["actions_per_game"]) is not int or data["actions_per_game"] < 10:
            raise ValueError("Public25 requires at least 10 concrete actions per game")
        ids = data["game_ids"]
        if (
            not isinstance(ids, list)
            or len(ids) != 25
            or not all(
                isinstance(item, str) and re.fullmatch(r"[a-z0-9]{4}-[a-f0-9]{8}", item)
                for item in ids
            )
            or len({item[:4] for item in ids}) != 25
        ):
            raise ValueError("Expected 25 distinct versioned public game IDs")
    return data


def runtime_paths(root):
    lock = tomllib.loads((root / "config/toolchains.toml").read_text(encoding="utf-8"))
    runtime = tomllib.loads(
        (root / "config/runtime.local.toml").read_text(encoding="utf-8")
    )
    for tool in ("python", "julia", "cargo", "rustc"):
        version = lock["rust" if tool in {"cargo", "rustc"} else tool]["version"]
        executable = Path(runtime[tool]["executable"])
        if (
            runtime[tool]["version"] != version
            or not executable.is_absolute()
            or not executable.is_file()
            or not os.access(executable, os.X_OK)
        ):
            raise ValueError(f"Toolchain mismatch: {tool}; rerun bootstrap")
    depot = Path(runtime["julia_cache"]["depot"])
    if not depot.is_absolute() or not depot.is_dir():
        raise ValueError("Invalid Julia depot")
    return runtime


def clean_environment():
    return {
        "PATH": "/usr/bin:/bin",
        "HOME": str(Path.home()),
        "LANG": "C.UTF-8",
        "PYTHONDONTWRITEBYTECODE": "1",
    }


def julia_command(root, runtime, script, *args):
    return [
        runtime["julia"]["executable"],
        "--startup-file=no",
        f"--project={root / 'julia/TddESCat'}",
        script,
        *args,
    ]


def julia_environment(runtime):
    return {
        **clean_environment(),
        "JULIA_DEPOT_PATH": os.pathsep.join(
            [runtime["julia_cache"]["depot"], str(Path.home() / ".julia"), ""]
        ),
        "JULIA_LOAD_PATH": "@:@stdlib",
    }


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def append_assertion(run_dir, identifier, passed, evidence, reason=None):
    record = {
        "id": identifier,
        "status": "BLOCKED" if passed is None else "PASS" if passed else "FAIL",
        "evidence": evidence,
        "reason": reason,
    }
    with (run_dir / "grade/assertions.jsonl").open("a", encoding="utf-8") as output:
        output.write(json.dumps(record, ensure_ascii=False) + "\n")


def worktree_digest(root, *, sources_only=False):
    files = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root,
    )
    digest = sha256()
    for name in sorted(set(files.split(b"\0")) - {b""}):
        if sources_only and not (
            name.startswith((b"julia/TddESCat/", b"python/src/", b"protocol/"))
            or name
            in (
                b"scripts/run.jl",
                b"config/autonomous_public.toml",
                b"config/stitch.toml",
                b"config/bench_server.toml",
                b"python/uv.lock",
                b"Cargo.lock",
            )
        ):
            continue
        path = root / os.fsdecode(name)
        if path.is_file():
            digest.update(name + b"\0")
            digest.update(sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def run_task(root, config_path, task, run_dir, runtime):
    from .isolation import private_network

    kind = task["kind"]
    expected = task["game_ids"] if kind == "arc_public25" else KIND_IDS[kind]
    if kind == "autonomous_offline":
        agent = tomllib.loads(task["agent_config"].read_text())
        if agent.get("planning", {}).get("relation_goals", False):
            expected = (*expected, "autonomous_learned_task")
        if agent["learning"].get("sequences", False):
            expected = (*expected, "autonomous_goal_program")
            if agent.get("planning", {}).get("relation_goals", False):
                expected = (*expected, "autonomous_learned_policy")
    official_local = kind in (
        "fixture",
        "evidence",
        "motion",
        "online",
        "movement",
        "movement_covariance",
        "movement_boundaries",
        "planning_public",
        "planning_composition",
        "movement_composition",
        "resource_composition",
        "camera_composition",
        "association_recovery",
        "association_online",
        "association_revision",
        "association_background",
        "sequence_learning",
        "measurement_learning",
        "measurement_goal",
        "projection_revision",
        "projected_program",
        "relation_goal",
        "learned_relationships",
        "learned_policy",
        "object_interventions",
    )
    offline_arc = kind in ("arc_offline", "autonomous_offline", "arc_public25")
    isolated = (
        official_local
        or offline_arc
        or kind in ("stitch", "stitch_reference", "association_kernel", "stitch_growth")
    )
    environment = (
        "official_offline_http"
        if offline_arc
        else "synthetic_official_http"
        if official_local
        else "protocol_stub"
        if kind == "protocol"
        else "real_public"
        if kind == "real_public"
        else "offline"
    )
    contracts = Contracts(root / "protocol/v1")
    locks = {
        language: sha256((root / path).read_bytes()).hexdigest()
        for language, path in (
            ("python", "python/uv.lock"),
            ("julia", "julia/TddESCat/Manifest.toml"),
            ("rust", "Cargo.lock"),
        )
    }
    manifest = {
        "schema_version": 1,
        "suite_id": task["output_name"],
        "run_id": run_dir.name,
        "git_commit": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True
        ).strip(),
        "worktree_sha256": worktree_digest(root),
        "config_sha256": sha256(config_path.read_bytes()).hexdigest(),
        "locks": locks,
        "environment": environment,
        "isolation": "linux_namespaces"
        if isolated or kind in ("stitch", "real_public")
        else "local_development",
        "started_at": now(),
    }
    contracts.validate("manifest", manifest)
    write_json(run_dir / "public/manifest.json", manifest)
    write_json(
        run_dir / "public/source-identity.json",
        {"solver_source_sha256": worktree_digest(root, sources_only=True)},
    )
    (run_dir / "grade").mkdir()
    command = [
        runtime["python"]["executable"],
        "-m",
        MODULES[task["kind"]],
        str(config_path),
        str(run_dir),
    ]
    if isolated:
        command = private_network(command, (run_dir,))
    with (run_dir / "grade/process.log").open("wb") as log:
        with subprocess.Popen(
            command,
            cwd=root,
            env=clean_environment(),
            stdout=log,
            stderr=log,
            start_new_session=True,
        ) as proc:
            try:
                exit_code = proc.wait(task.get("timeout_seconds"))
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(8)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
                exit_code = 124

    assertions = run_dir / "grade/assertions.jsonl"
    measurements = {}
    digests = {}
    if assertions.exists():
        for line in assertions.read_text(encoding="utf-8").splitlines():
            entry = json.loads(line)
            if entry["id"] in measurements:
                raise ValueError(f"Duplicate assertion: {entry['id']}")
            for evidence in entry["evidence"]:
                resolved = (run_dir / evidence).resolve()
                if not resolved.is_relative_to(run_dir):
                    entry.update(
                        status="FAIL",
                        reason="assertion_evidence_missing_or_outside_run",
                    )
                    continue
                files = (
                    sorted(path for path in resolved.rglob("*") if path.is_file())
                    if resolved.is_dir()
                    else [resolved]
                )
                if not files or any(
                    not path.is_file() or not path.resolve().is_relative_to(run_dir)
                    for path in files
                ):
                    entry.update(
                        status="FAIL",
                        reason="assertion_evidence_missing_or_outside_run",
                    )
                    continue
                for path in files:
                    name = path.relative_to(run_dir).as_posix()
                    if name not in digests:
                        with path.open("rb") as stream:
                            digests[name] = file_digest(stream, "sha256").hexdigest()
            measurements[entry["id"]] = entry
        write_json(run_dir / "grade/evidence-index.json", digests)
    verdicts = [
        {
            "id": member,
            "status": measurements.get(member, {}).get("status", "NOT_RUN"),
            "assertion_refs": ["grade/assertions.jsonl", "grade/evidence-index.json"]
            if member in measurements
            else [],
            "reason": measurements.get(member, {}).get(
                "reason", None if member in measurements else f"worker_exit_{exit_code}"
            ),
        }
        for member in expected
    ]
    passed = (
        exit_code == 0
        and set(measurements) == set(expected)
        and all(v["status"] == "PASS" for v in verdicts)
    )
    blocked = (
        exit_code == 3
        and set(measurements) == set(expected)
        and any(member["status"] == "BLOCKED" for member in verdicts)
    )
    acceptance = {
        "schema_version": 1,
        "run_id": run_dir.name,
        "suite_id": task["output_name"],
        "status": "PASS" if passed else "BLOCKED" if blocked else "FAIL",
        "evidence_scope": {
            "arc_public25": "environment",
            "fixture": "environment",
            "protocol": "protocol",
        }.get(kind, "evidence"),
        "tasks": verdicts,
    }
    contracts.validate("acceptance", acceptance)
    write_json(run_dir / "public/acceptance.json", acceptance)
    report = [
        f"# {task['output_name']} 验证",
        "",
        f"总体状态为 {acceptance['status']}。执行退出码为 `{exit_code}`。",
        "",
        *[f"- `{entry['id']}` {entry['status']}" for entry in verdicts],
    ]
    (run_dir / "public/report.md").write_text(
        "\n".join(report) + "\n", encoding="utf-8"
    )
    if kind in (
        "arc_public25",
        "autonomous_offline",
        "association_recovery",
        "association_kernel",
        "association_online",
        "association_revision",
        "association_background",
        "sequence_learning",
        "sequence_depth",
        "trace_learning",
        "measurement_learning",
        "measurement_goal",
        "projection_revision",
        "relation_goal",
        "stitch_growth",
    ):
        write_artifact_index(run_dir)
    print(f"{acceptance['status']} {run_dir}", flush=True)
    return 0 if passed else 3 if blocked else 1


def main():
    root = Path.cwd()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path)
    parser.add_argument(
        "--prerequisite", type=Path, help="The upstream run's public/acceptance.json"
    )
    args = parser.parse_args()
    config_path = args.config.resolve()
    header = tomllib.loads(config_path.read_text(encoding="utf-8"))
    suite = "tasks" in header
    task = read_task(config_path) if not suite else None
    if not suite and task["kind"] not in MODULES:
        parser.error(f"Unsupported task kind: {task['kind']}")
    runtime = runtime_paths(root)
    name = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    run_dir = (
        args.run_dir
        or (config_path.parent / header["artifact_root"] if suite else root / "runs")
        / f"{name}-{header['suite_id'] if suite else task['output_name']}-{uuid4().hex[:8]}"
    ).resolve()
    run_dir.mkdir(parents=True)
    if suite:
        from .suite import run_suite

        sys.exit(run_suite(root, config_path, run_dir, runtime, args.prerequisite))
    sys.exit(run_task(root, config_path, task, run_dir, runtime))


if __name__ == "__main__":
    main()
