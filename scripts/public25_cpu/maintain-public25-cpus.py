#!/usr/bin/env python3
"""Keep each live public case and its separately managed learning units on its assigned guest CPU."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time


def read(path):
    try:
        return json.loads(path.read_bytes())
    except FileNotFoundError:
        return {}


def write(path, value):
    temp = path.with_suffix(".incoming")
    temp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(temp, path)


def units(tag):
    proc = subprocess.run(
        [
            "systemctl",
            "--user",
            "show",
            f"pub25-{tag}-*.service",
            "tddesc-solver-*.scope",
            "tddesc-stitch-*.service",
            "--property=Id,ActiveState,ControlGroup,BindsTo",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    rows = {}
    for block in proc.stdout.strip().split("\n\n"):
        d = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        if d.get("ActiveState") in ("active", "activating") and d.get("ControlGroup"):
            rows[d["Id"]] = d
    return rows


def assignments(root, tag, pins, live):
    targets = {}
    for key, cpu in pins.items():
        arm, game = key.split("/")
        name = f"pub25-{tag}-{arm}-{game.split('-')[0]}.service"
        if name in live:
            targets[name] = (key, cpu, "case")
        case = root / arm / game
        for pub in (case / "public", case / "transport-retry/public"):
            scope = read(pub / "supervision.json").get("scope", "")
            if (
                re.fullmatch(r"tddesc-solver-[0-9a-f]{32}\.scope", scope)
                and scope in live
            ):
                targets[scope] = (key, cpu, "solver")
    for name, unit in live.items():
        if name.startswith("tddesc-stitch-"):
            parents = {
                targets[parent]
                for parent in unit["BindsTo"].split()
                if parent in targets and targets[parent][2] == "solver"
            }
            if len(parents) == 1:
                key, cpu, _ = parents.pop()
                targets[name] = (key, cpu, "stitch")
    return targets


def enforce(item):
    unit, path, cpu = item
    assigned = path / "cpuset.cpus"
    effective = path / "cpuset.cpus.effective"
    try:
        actual = effective.read_text().strip() if effective.exists() else None
        configured = assigned.read_text().strip() if assigned.exists() else None
        if actual != str(cpu) or configured != str(cpu):
            command = subprocess.run(
                [
                    "systemctl",
                    "--user",
                    "set-property",
                    "--runtime",
                    unit,
                    f"AllowedCPUs={cpu}",
                ],
                capture_output=True,
                text=True,
            )
            if command.returncode:
                return unit, {"error": command.stderr.strip(), "observed": actual}
        configured = assigned.read_text().strip()
        actual = effective.read_text().strip()
        return unit, {
            "configured": configured,
            "effective": actual,
            "verified": actual == configured == str(cpu),
        }
    except (OSError, ValueError) as exc:
        return unit, {"error": str(exc)}


def pin_userspace(path, cpu):
    count = 0
    protected = []
    errors = []
    corrected = 0
    for membership in path.rglob("cgroup.threads"):
        try:
            tids = membership.read_text().split()
        except FileNotFoundError:
            continue
        for raw in tids:
            tid = int(raw)
            try:
                mask = os.sched_getaffinity(tid)
                if mask == {cpu}:
                    count += 1
                    continue
                proc = Path("/proc") / raw
                rawstat = (proc / "stat").read_text()
                fields = rawstat.rsplit(")", 1)[1].split()
                if int(fields[6]) & 0x04000000:  # Linux PF_NO_SETAFFINITY
                    protected.append(
                        dict(
                            tid=tid,
                            comm=(proc / "comm").read_text().strip(),
                            cpus=sorted(mask),
                        )
                    )
                    continue
                # TIDs can be recycled. Reconfirm membership before changing affinity.
                expected = "/" + str(membership.parent.relative_to("/sys/fs/cgroup"))
                if "0::" + expected not in (proc / "cgroup").read_text().splitlines():
                    continue
                os.sched_setaffinity(tid, {cpu})
                if os.sched_getaffinity(tid) == {cpu}:
                    corrected += 1
                    count += 1
                else:
                    errors.append({"tid": tid, "error": "affinity did not persist"})
            except (ProcessLookupError, FileNotFoundError):
                continue
            except OSError as exc:
                errors.append({"tid": tid, "error": str(exc)})
    return dict(
        mode="per_thread",
        verified=count > 0 and not errors,
        userspace_threads=count,
        corrected=corrected,
        kernel_managed_threads=protected,
        errors=errors,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    root = args.output.resolve(strict=True)
    guards = root / "operational-cpusets.json"
    lock = (root / ".operational-cpusets.lock").open("a")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    plan = read(root / "plan.json")
    pins = plan["cpu_assignment"]
    if len(pins) != len(set(pins.values())) or any(
        not isinstance(cpu, int) or cpu < 0 for cpu in pins.values()
    ):
        raise ValueError("Invalid CPU allocation in frozen plan")
    tag = hashlib.sha256(str(root).encode()).hexdigest()[:12]
    ledger = read(guards) or {
        "schema_version": 1,
        "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "runner_sha256": plan["runner_sha256"],
        "units": {},
    }
    digest = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    if ledger["script_sha256"] != digest:
        ledger.setdefault("previous_helpers", []).append(
            dict(sha256=ledger["script_sha256"], until=time.time())
        )
        ledger["script_sha256"] = digest
    ledger["verified_definition"] = (
        "All observed affinity-adjustable threads match the assigned CPU; PF_NO_SETAFFINITY threads are listed separately"
    )
    rootgroup = Path("/sys/fs/cgroup")
    manager = (
        rootgroup
        / "user.slice"
        / f"user-{os.getuid()}.slice"
        / f"user@{os.getuid()}.service"
    )
    while True:
        available = (manager / "cgroup.controllers").read_text().split()
        live = units(tag)
        targets = assignments(root, tag, pins, live)
        updated = False

        def apply(item):
            unit, (_, cpu, _) = item
            path = rootgroup / live[unit]["ControlGroup"].lstrip("/")
            prior = ledger["units"].get(unit, {})
            failure = prior.get("cpuset_failure")
            if "cpuset" in available and not failure:
                _, result = enforce((unit, path, cpu))
                if result.get("verified"):
                    return unit, {**result, "mode": "cgroup"}
                failure = result.get("error", "Different effective cgroup mask")
            result = pin_userspace(path, cpu)
            corrected = result.pop("corrected")
            result["total_user_thread_corrections"] = (
                prior.get("total_user_thread_corrections", 0) + corrected
            )
            if failure:
                result["cpuset_failure"] = failure
            return unit, result

        items = list(targets.items())
        with ThreadPoolExecutor(max_workers=4) as pool:
            for unit, result in pool.map(apply, items):
                key, cpu, role = targets[unit]
                new = dict(
                    key=key,
                    cpu=cpu,
                    role=role,
                    cgroup=live[unit]["ControlGroup"],
                    **result,
                )
                prior = ledger["units"].get(unit, {})
                if {
                    k: v
                    for k, v in prior.items()
                    if k not in ("updated", "first_verified")
                } != new:
                    now = time.time()
                    new.update(
                        updated=now,
                        first_verified=prior.get("first_verified")
                        or (now if result.get("verified") else None),
                    )
                    ledger["units"][unit] = new
                    updated = True
        summary = {
            "delegated": "cpuset" in available,
            "live_targets": len(targets),
            "live_kernel_managed_threads": sum(
                len(ledger["units"].get(unit, {}).get("kernel_managed_threads", []))
                for unit in targets
            ),
            "verified_live_targets": sum(
                ledger["units"].get(unit, {}).get("verified", False) for unit in targets
            ),
        }
        if ledger.get("summary") != summary or updated:
            ledger.update(summary=summary, observed_at=time.time())
            write(guards, ledger)
            print(json.dumps(summary, sort_keys=True), flush=True)
        if args.once or read(root / "launcher.json").get("status", "").startswith(
            "CLOSED"
        ):
            break
        time.sleep(2)


if __name__ == "__main__":
    main()
