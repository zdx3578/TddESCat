#!/usr/bin/env python3
"""Read public receipts and current Linux process affinity without contacting a game."""

import argparse
import json
import os
import time
from pathlib import Path


def mask(pid):
    try:
        return sorted(os.sched_getaffinity(pid))
    except (ProcessLookupError, PermissionError):
        return None


def read(path):
    try:
        return json.loads(path.read_bytes())
    except FileNotFoundError:
        return {}


def process_records(threads=False):
    rows = []
    tick_rate = os.sysconf("SC_CLK_TCK")
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            args = os.fsdecode((proc / "cmdline").read_bytes()).rstrip("\0").split("\0")
            pid = int(proc.name)
            role = None
            if len(args) >= 8 and "_game" in args and args[1:2] == ["-u"]:
                mode = args.index("_game")
                if len(args) != mode + 6:
                    continue
                role, case = (
                    "worker",
                    Path(args[mode + 4]) / args[mode + 1] / args[mode + 5],
                )
            elif args[1:3] == ["-m", "tddesc_env.serve"] and "--work" in args:
                role, case = "sdk", Path(args[args.index("--work") + 1]).parent.parent
            elif (
                "--supervised" in args
                and "--public-dir" in args
                and Path(args[0]).name == "julia"
            ):
                role, case = "solver", Path(args[args.index("--public-dir") + 1]).parent
            elif Path(args[0]).name == "tddesc-stitch" and "--manifest" in args:
                manifest = Path(args[args.index("--manifest") + 1])
                pub = next((p for p in manifest.parents if p.name == "public"), None)
                if pub is None:
                    continue
                role, case = "stitch", pub.parent
            if role is None:
                continue
            scope = (proc / "cgroup").read_text().strip().splitlines()
            item = dict(pid=pid, cpus=mask(pid), cgroup=scope, role=role)
            stats = (proc / "stat").read_text().rsplit(")", 1)[1].split()
            item.update(
                start_ticks=int(stats[19]),
                cpu_seconds=(int(stats[11]) + int(stats[12])) / tick_rate,
                last_processor=int(stats[36]),
                process_state=stats[0],
            )
            for line in scope:
                if line.startswith("0::/"):
                    group = line[3:]
                    counters = Path("/sys/fs/cgroup") / group.lstrip("/") / "cpu.stat"
                    if counters.exists():
                        stat = {
                            r.split()[0]: int(r.split()[1])
                            for r in counters.read_text().splitlines()
                        }
                        item.update(group=group, cgroup_usage_usec=stat["usage_usec"])
                    break
            if threads:
                worker_masks = set()
                protected = []
                for tid in (proc / "task").iterdir():
                    try:
                        actual = mask(int(tid.name))
                        if actual is None:
                            continue
                        ts = (tid / "stat").read_text().rsplit(")", 1)[1].split()
                        if int(ts[6]) & 0x04000000:
                            protected.append(
                                dict(
                                    tid=int(tid.name),
                                    comm=(tid / "comm").read_text().strip(),
                                    start_ticks=int(ts[19]),
                                    cpus=actual,
                                    cpu_ticks=int(ts[11]) + int(ts[12]),
                                    last_processor=int(ts[36]),
                                )
                            )
                        else:
                            worker_masks.add(tuple(actual))
                    except (FileNotFoundError, ProcessLookupError):
                        continue
                item["userspace_thread_masks"] = sorted(worker_masks)
                item["protected_kernel_threads"] = protected
                item["thread_masks"] = sorted(
                    worker_masks | {tuple(t["cpus"]) for t in protected}
                )
            rows.append((case.parent if case.name == "transport-retry" else case, item))
        except (PermissionError, FileNotFoundError, ProcessLookupError, IndexError):
            continue
    return rows


def summarize(root, threads):
    plan = read(root / "plan.json")
    processes = process_records(threads)
    rows = {}
    for key, cpu in plan["cpu_assignment"].items():
        case = root / key
        attempt = (
            case / "transport-retry" if (case / "transport-retry").exists() else case
        )
        grade = attempt / "grade"
        pub = attempt / "public"
        cmd = pub / "commands"
        reset = read(cmd / "c000000002.json")
        action = read(cmd / "c000000003.json")
        matched = [item for p, item in processes if p == case]
        for item in matched:
            item["pinned"] = item["cpus"] == [cpu] and all(
                list(m) == [cpu] for m in item.get("thread_masks", [])
            )
            item["userspace_pinned"] = item["cpus"] == [cpu] and all(
                list(m) == [cpu] for m in item.get("userspace_thread_masks", [])
            )
        receipts = {}
        for record in sorted(grade.glob("sdk-admission-*.json")):
            admission = read(record)
            receipts[record.name] = {
                k: admission[k]
                for k in (
                    "state",
                    "admitted",
                    "ready_at",
                    "startup_seconds",
                    "assigned_cpu",
                    "live_cpu_masks",
                )
                if k in admission
            }
        rows[key] = dict(
            cpu=cpu,
            processes=matched,
            worker_start=read(case / "grade/runner-started.json").get("started"),
            sdk_receipts=receipts,
            first_command=read(cmd / "c000000001.json").get("completion"),
            reset_confirmed=reset.get("kind") == "reset"
            and reset.get("completion") == "confirmed",
            first_action_confirmed=action.get("kind") == "action"
            and action.get("completion") == "confirmed",
            final_verdict=read(case / "grade/runner-result.json").get("verdict"),
        )
    per_arm = {}
    for arm in plan["arms"]:
        selected = [r for k, r in rows.items() if k.startswith(arm + "/")]
        counts = {}
        for role in ("worker", "sdk", "solver", "stitch"):
            counts["live_" + role + "_cases"] = sum(
                any(p["role"] == role for p in row["processes"]) for row in selected
            )
        for field in (
            "worker_start",
            "first_command",
            "reset_confirmed",
            "first_action_confirmed",
            "final_verdict",
        ):
            counts[field] = sum(bool(row[field]) for row in selected)
        counts["cases_with_mismatching_affinity"] = sum(
            any(not p["pinned"] for p in row["processes"]) for row in selected
        )
        if threads:
            counts["cases_with_mismatching_userspace_affinity"] = sum(
                any(not p["userspace_pinned"] for p in row["processes"])
                for row in selected
            )
            counts["kernel_affinity_protected_threads"] = sum(
                len(p["protected_kernel_threads"])
                for row in selected
                for p in row["processes"]
            )
        per_arm[arm] = counts
    return dict(
        schema_version=1,
        affinity_observation="all_threads" if threads else "process_leaders",
        clock_ticks_per_second=os.sysconf("SC_CLK_TCK"),
        observed_at=time.time(),
        campaign=str(root),
        runner_sha256=plan["runner_sha256"],
        guest_cpus=sorted(os.sched_getaffinity(0)),
        summary=per_arm,
        cases=rows,
    )


def sample_cpu(before, after):
    seconds = after["observed_at"] - before["observed_at"]
    summary = {}
    for key, row in after["cases"].items():
        previous = {
            p["group"]: p["cgroup_usage_usec"]
            for p in before["cases"][key]["processes"]
            if "group" in p
        }
        current = {
            p["group"]: p["cgroup_usage_usec"] for p in row["processes"] if "group" in p
        }
        deltas = {
            g: (usec - previous[g]) / 1e6
            for g, usec in current.items()
            if g in previous and usec >= previous[g]
        }

        def kernel_ticks(record):
            return {
                (t["tid"], t["start_ticks"]): t["cpu_ticks"]
                for p in record["processes"]
                for t in p.get("protected_kernel_threads", [])
            }

        ticks_before = kernel_ticks(before["cases"][key])
        ticks_after = kernel_ticks(row)
        kernel_seconds = [
            (n - ticks_before[k]) / after["clock_ticks_per_second"]
            for k, n in ticks_after.items()
            if k in ticks_before
        ]
        row["cgroup_cpu_sample"] = dict(
            seconds=seconds,
            matched_groups=deltas,
            sampled_kernel_helpers=len(kernel_seconds),
            kernel_helper_cpu_seconds=sum(kernel_seconds),
            sampled_cores=sum(deltas.values()) / seconds if deltas else None,
        )
    for arm in after["summary"]:
        samples = [
            row["cgroup_cpu_sample"]
            for key, row in after["cases"].items()
            if key.startswith(arm + "/")
        ]
        cores = [r["sampled_cores"] for r in samples if r["sampled_cores"] is not None]
        summary[arm] = {
            "sampled_cases": len(cores),
            "cases_with_cpu_time": sum(c > 0 for c in cores),
            "aggregate_guest_cores": sum(cores),
            "sampled_kernel_helpers": sum(r["sampled_kernel_helpers"] for r in samples),
            "kernel_helper_cpu_seconds": sum(
                r["kernel_helper_cpu_seconds"] for r in samples
            ),
            "seconds": seconds,
        }
    after["cpu_sample"] = summary
    return after


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--threads", action="store_true")
    parser.add_argument("--save", type=Path)
    parser.add_argument("--sample-seconds", type=float, default=0.0)
    args = parser.parse_args()
    if args.sample_seconds < 0:
        parser.error("sample duration must be nonnegative")
    report = summarize(args.output.resolve(strict=True), args.threads)
    if args.sample_seconds:
        time.sleep(args.sample_seconds)
        report = sample_cpu(
            report, summarize(args.output.resolve(strict=True), args.threads)
        )
    if args.save:
        args.save.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(json.dumps(report["summary"], sort_keys=True))
    else:
        print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
