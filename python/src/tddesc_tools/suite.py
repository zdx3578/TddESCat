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


def run_suite(root, path, run, runtime, prerequisite=None):
    suite, ordered = parse_suite(path)
    contracts = Contracts(root / "protocol/v1")
    required_previous = suite.get("prerequisite_suite")
    previous = None
    if prerequisite is not None:
        previous = json.loads(prerequisite.read_bytes())
        contracts.validate("acceptance", previous)
    upstream_pass = required_previous is None or (
        previous is not None
        and previous["suite_id"] == required_previous
        and previous["status"] == "PASS"
    )
    origin = {
        "worktree_sha256": worktree_digest(root),
        "suite_config_sha256": sha256(path.read_bytes()).hexdigest(),
        "prerequisite_sha256": None
        if prerequisite is None
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
    write_json(run / "public/acceptance.json", report)
    write_json(run / "public/provenance.json", origin)
    print(f"{status} {run}", flush=True)
    return {"PASS": 0, "BLOCKED": 3}.get(status, 1)
