"""Run acceptance tasks with checked dependencies and hash-linked reports."""

import json
import re
import subprocess
import tomllib
from hashlib import sha256

from .contracts import Contracts
from .run import read_task, run_task, worktree_digest, write_json


def parse_suite(path):
    definition = tomllib.loads(path.read_text(encoding="utf-8"))
    fields = {"schema_version", "suite_id", "artifact_root", "tasks"}
    if (
        not fields <= definition.keys()
        or definition.keys() - fields - {"prerequisite_suite"}
        or type(definition["schema_version"]) is not int
        or definition["schema_version"] != 1
        or not re.fullmatch(r"[A-Za-z0-9_.-]+", definition["suite_id"])
    ):
        raise ValueError("Malformed suite")
    tasks = {}
    for task in definition["tasks"]:
        identifier = task["id"]
        if (
            set(task) != {"id", "config", "required", "depends_on"}
            or identifier in tasks
            or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]*", identifier)
            or type(task["required"]) is not bool
            or not isinstance(task["depends_on"], list)
        ):
            raise ValueError("Malformed or duplicate task")
        config_path = (path.parent / task["config"]).resolve()
        if config_path.parent != path.parent or not config_path.is_file():
            raise ValueError(
                "Suite task config must be a member of this config directory"
            )
        tasks[identifier] = {**task, "config": config_path}
    if not tasks:
        raise ValueError("Suite must have tasks")
    prior = definition.get("prerequisite_suite")
    if prior is not None and (
        not isinstance(prior, str)
        or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]*", prior)
        or prior == definition["suite_id"]
    ):
        raise ValueError("Invalid prerequisite suite")
    remaining = dict(tasks)
    order = []
    ready = set()
    while remaining:
        available = [
            identifier
            for identifier, task in remaining.items()
            if set(task["depends_on"]) <= ready
        ]
        if not available:
            raise ValueError("Unknown dependency or cycle in the suite")
        for identifier in available:
            ready.add(identifier)
            order.append(remaining.pop(identifier))
    return definition, order


def verified_prerequisite(contracts, suite_path, previous_path, identifier):
    if previous_path is None or not previous_path.is_file():
        return False
    previous = json.loads(previous_path.read_bytes())
    contracts.validate("acceptance", previous)
    if previous["suite_id"] != identifier or previous["status"] != "PASS":
        return False
    definition_path = suite_path.parent / (identifier + ".toml")
    _, expected = parse_suite(definition_path)
    grades = {task["id"]: task for task in previous["tasks"]}
    root = previous_path.resolve().parent.parent
    provenance_path = root / "public/provenance.json"
    if not provenance_path.is_file():
        return False
    provenance = json.loads(provenance_path.read_bytes())
    if (
        provenance.get("suite_config_sha256")
        != sha256(definition_path.read_bytes()).hexdigest()
    ):
        return False
    for task in expected:
        if not task["required"]:
            continue
        name = task["id"]
        result = grades.get(name, {})
        if result.get("status") != "PASS":
            return False
        child = root / "tasks" / name / "public"
        report, manifest = child / "acceptance.json", child / "manifest.json"
        if not report.is_file() or not manifest.is_file():
            return False
        if report.relative_to(root).as_posix() not in result["assertion_refs"]:
            return False
        report_bytes = report.read_bytes()
        if provenance.get(name) != {
            "acceptance_sha256": sha256(report_bytes).hexdigest(),
            "manifest_sha256": sha256(manifest.read_bytes()).hexdigest(),
        }:
            return False
        grade = json.loads(report_bytes)
        contracts.validate("acceptance", grade)
        if grade["status"] != "PASS":
            return False
    return True


def run_suite(root, path, run, runtime, prerequisite=None):
    suite, ordered = parse_suite(path)
    contracts = Contracts(root / "protocol/v1")
    required_previous = suite.get("prerequisite_suite")
    upstream_pass = required_previous is None or verified_prerequisite(
        contracts, path, prerequisite, required_previous
    )
    origin = {
        "worktree_sha256": worktree_digest(root),
        "suite_config_sha256": sha256(path.read_bytes()).hexdigest(),
        "prerequisite_sha256": None
        if prerequisite is None or not prerequisite.is_file()
        else sha256(prerequisite.read_bytes()).hexdigest(),
    }
    ledger = {}
    graded = []
    for entry in ordered:
        identifier = entry["id"]
        result = {"id": identifier, "assertion_refs": [], "reason": None}
        missing = [
            dep for dep in entry["depends_on"] if ledger[dep]["status"] != "PASS"
        ]
        if not upstream_pass or missing:
            source = required_previous if not upstream_pass else ",".join(missing)
            result.update(status="BLOCKED", reason=f"requires_pass:{source}")
        else:
            child = run / "tasks" / identifier
            child.mkdir(parents=True)
            task = read_task(entry["config"])
            try:
                run_task(root, entry["config"], task, child, runtime)
                report = child / "public" / "acceptance.json"
                report_bytes = report.read_bytes()
                accepted = json.loads(report_bytes)
                contracts.validate("acceptance", accepted)
                result.update(
                    status=accepted["status"],
                    assertion_refs=[report.relative_to(run).as_posix()],
                )
                origin[identifier] = {
                    "acceptance_sha256": sha256(report_bytes).hexdigest(),
                    "manifest_sha256": sha256(
                        (child / "public/manifest.json").read_bytes()
                    ).hexdigest(),
                }
                if accepted["status"] != "PASS":
                    reasons = [
                        v["reason"]
                        for v in accepted["tasks"]
                        if v["reason"] is not None
                    ]
                    result["reason"] = ",".join(reasons) or accepted["status"]
            except (OSError, ValueError, subprocess.SubprocessError) as exc:
                result.update(
                    status="FAIL", reason=f"runner_error:{type(exc).__name__}"
                )
        graded.append(result)
        ledger[identifier] = result
    mandatory = {ledger[x["id"]]["status"] for x in ordered if x["required"]}
    status = next((s for s in ("FAIL", "BLOCKED", "NOT_RUN") if s in mandatory), "PASS")
    report = {
        "schema_version": 1,
        "run_id": run.name,
        "suite_id": suite["suite_id"],
        "status": status,
        "evidence_scope": "evidence",
        "tasks": graded,
    }
    contracts.validate("acceptance", report)
    write_json(run / "public/provenance.json", origin)
    write_json(run / "public/acceptance.json", report)
    print(f"{status} {run}", flush=True)
    return {"PASS": 0, "BLOCKED": 3}.get(status, 1)
