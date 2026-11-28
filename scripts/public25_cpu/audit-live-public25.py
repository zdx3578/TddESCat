#!/usr/bin/env python3
"""Read one Public25 campaign, systemd user services, and its verified solver processes. No SDK calls."""
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
from hashlib import sha256
import json
from pathlib import Path
import re
import subprocess


def timestamp():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def read(path, default=None):
    try:
        return json.loads(path.read_bytes())
    except FileNotFoundError:
        return default


def require(condition, message):
    if not condition:
        raise ValueError(message)


def payload(public, digest):
    require(isinstance(digest, str) and re.fullmatch(r"[a-f0-9]{64}", digest), "invalid response digest")
    raw = (public / "blobs" / digest).read_bytes()
    require(sha256(raw).hexdigest() == digest, "response digest differs")
    return json.loads(raw)


def transaction(public, game, event):
    idx, ref, eid = event["sequence"], event["command_ref"], event["event_id"]
    require(ref == f"c{idx:09d}" and re.fullmatch(r"e-[a-f0-9]+-c\d+", eid), "invalid event identity")
    cmd = read(public / "commands" / (ref + ".json")) or {}
    require(cmd.get("completion") == event["completion"] == "confirmed", "unconfirmed transaction")
    require(cmd["command_id"] == ref and cmd["event_id"] == eid and cmd["expected_game_id"] == game
            and cmd["response_blob"] == event["response_blob"], "receipt binding differs")
    obs = payload(public, event["response_blob"])
    action = obs["action_input"]["id"]
    require(action == event["action"]["id"] and obs["game_id"] == game, "game or action differs")
    require((cmd["kind"], cmd["path"]) == (("reset", "/api/cmd/RESET") if action == 0
            else ("action", f"/api/cmd/ACTION{action}")), "kind/path differs")
    require(cmd.get("expected_guid") in (None, obs["guid"]), "GUID differs")
    return obs


def official_counts(public, game, row):
    replay = read(public / "replay.json") or {}
    applied = replay.get("applied_events", [])
    require(applied and replay["through_event"] == applied[-1]["event_id"], "missing official replay")
    boundaries = []
    for item in (applied[0], applied[-1]):
        eid = item["event_id"]
        require(re.fullmatch(r"e-[a-f0-9]+-c\d+", eid), "invalid replay event")
        event = read(public / "events" / (eid + ".json")) or {}
        require(event["event_id"] == eid and event["response_blob"] == item["response_blob"], "replay event differs")
        boundaries.append(transaction(public, game, event))
    start, last = boundaries
    require(start["action_input"]["id"] == 0 and row["state"] == last["state"], "replay boundary differs")
    n = row.get("confirmed_actions", row.get("actions"))
    peak = row["peak_levels"]
    require(type(n) is int and 0 <= n < len(applied) and type(peak) is int
            and peak >= last["levels_completed"], "official totals differ")
    won = False
    if row.get("verdict") == "WIN":
        require(row["scorecard_win"] is True and row["state"] == "WIN", "missing official win evidence")
        closing = next((cmd for f in sorted((public / "commands").glob("c*.json"), reverse=True)
                        if (cmd := read(f)).get("kind") == "close_scorecard"), {})
        require(closing.get("completion") == "confirmed" and closing.get("response_blob") == row["scorecard_sha256"],
                "missing confirmed scorecard")
        card = payload(public, row["scorecard_sha256"])
        won = any(e.get("id") == game and e.get("completed") is True and any(
            run.get("guid") == last["guid"] and run.get("state") == "WIN" for run in e.get("runs", [])
        ) for e in card.get("environments", []))
        require(won, "scorecard does not confirm final game and GUID")
    return dict(source="official_replay_and_result", reset=len(applied)-n, action=n, peak=peak,
                last_state=last["state"], verified_win=won)


def receipt_counts(public, game, row):
    warnings = []
    if row.get("game_id") == game and row.get("verified") is True and row.get("worker_exit") == 0 and row.get("replay_exit") == 0:
        try:
            return official_counts(public, game, row)
        except (OSError, KeyError, TypeError, ValueError, StopIteration) as e:
            warnings.append("official result could not be corroborated: " + str(e))
    stats = dict(source="confirmed_transactions", reset=0, action=0, peak=None, last_state=None, verified_win=False)
    latest = -1
    for f in (public / "events").glob("*.json"):
        try:
            event = read(f) or {}
            require(f.stem == event["event_id"], "event filename differs")
            obs = transaction(public, game, event)
            n = obs["levels_completed"]
            require(type(n) is int and n >= 0, "invalid levels_completed")
            stats["reset" if event["action"]["id"] == 0 else "action"] += 1
            stats["peak"] = max(stats["peak"] or 0, n)
            if event["sequence"] > latest:
                stats["last_state"] = obs["state"]
                latest = event["sequence"]
        except (OSError, KeyError, TypeError, ValueError) as e:
            warnings.append(f"{f.name}: {e}")
    if warnings:
        stats.update(unreadable_evidence=len(warnings), first_errors=warnings[:3])
    return stats


def systemd(units):
    if not units:
        return {}, None
    try:
        p = subprocess.run(["systemctl", "--user", "show", "--no-pager",
                            "--property=Id,LoadState,ActiveState,SubState,MainPID", "--", *sorted(units)],
                           capture_output=True, text=True, timeout=12, check=False)
        states = [dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
                  for block in p.stdout.strip().split("\n\n")]
        records = {s["Id"]: s for s in states if s.get("Id")}
        return records, (p.stderr.strip()[:300] or f"systemctl exit {p.returncode}") if p.returncode and not records else None
    except (OSError, subprocess.TimeoutExpired) as e:
        return {}, str(e)


# Linux include/linux/sched.h. The flag describes an affinity restriction,
# independently of the thread name and of the amount of CPU time observed.
PF_NO_SETAFFINITY = 0x04000000


def thread_sample(task):
    record = dict(tid=int(task.name), state=None, mask=None, protected=None)
    try:
        status = dict(line.split(":\t", 1) for line in (task / "status").read_text().splitlines() if ":\t" in line)
        record.update(state=status["State"].split()[0], mask=status["Cpus_allowed_list"])
    except (OSError, KeyError, IndexError):
        pass
    try:
        # comm may contain spaces and right parentheses. Field 3 follows the last ')'.
        stat = (task / "stat").read_text()
        head, sep, tail = stat.rpartition(")")
        tid, opening, comm = head.partition("(")
        fields = tail.split()
        if not sep or not opening or int(tid) != record["tid"]:
            raise ValueError("stat does not identify the sampled task")
        flags = int(fields[6])  # Field 9 of proc_pid_stat(5).
        record.update(protected=bool(flags & PF_NO_SETAFFINITY), flags=hex(flags), comm=comm,
                      cpu_ticks=int(fields[11]) + int(fields[12]))
    except (OSError, KeyError, IndexError, ValueError):
        pass
    return record


def masks_match(masks, assigned):
    if assigned is None or not masks:
        return None
    if any(mask is not None and mask != str(assigned) for mask in masks):
        return False
    return None if None in masks else True


def processes(proc=Path("/proc")):
    found = defaultdict(list)
    for folder in proc.glob("[0-9]*"):
        try:
            if (folder / "comm").read_text().strip() != "julia":
                continue
            args = (folder / "cmdline").read_bytes().decode(errors="replace").rstrip("\0").split("\0")
            if Path(args[0]).name != "julia" or "--supervised" not in args or "--public-dir" not in args:
                continue
            target = args[args.index("--public-dir") + 1]
            script = args[args.index("--supervised") - 1]
            if not script.endswith("/scripts/run.jl"):
                continue
            cgroups = (folder / "cgroup").read_text().splitlines()
            scope = next(s for line in cgroups for s in line.split("/") if re.fullmatch(r"tddesc-solver-[0-9a-f]{32}\.scope", s))
            tasks = [thread_sample(task) for task in (folder / "task").iterdir()]
            pid = int(folder.name)
            main = next(t for t in tasks if t["tid"] == pid)
            if main["state"] in ("Z", "X", "T", "t", None):
                continue
            adjustable = [t for t in tasks if t["protected"] is False]
            found[(scope, target, script)].append(dict(pid=pid, state=main["state"], Cpus_allowed_list=main["mask"],
                thread_masks=dict(Counter(t["mask"] for t in tasks if t["mask"] is not None)),
                unreadable_thread_masks=sum(t["mask"] is None for t in tasks),
                adjustable_thread_masks=dict(Counter(t["mask"] for t in adjustable if t["mask"] is not None)),
                unreadable_adjustable_masks=sum(t["mask"] is None for t in adjustable),
                protected_threads=[t for t in tasks if t["protected"]],
                unknown_class_threads=[t for t in tasks if t["protected"] is None]))
        except (OSError, IndexError, KeyError, ValueError, StopIteration):
            continue
    return found


def snapshot(root, proc=Path("/proc"), query=systemd):
    begin = timestamp()
    plan = read(root / "plan.json")
    if plan is None:
        return dict(run=str(root), sample_started_utc=begin, sample_ended_utc=timestamp(), state="awaiting_plan", arms={})
    require("arms" in plan, "published plan has no arms")
    launcher = read(root / "launcher.json", {})
    read_procs_at = timestamp()
    found = processes(proc)
    read_procs_end = timestamp()
    report = dict(run=str(root), sample_started_utc=begin, proc_sample_utc=[read_procs_at, read_procs_end], arms={})
    groups = {}
    units = set()
    for arm, pin in plan["arms"].items():
        aggregate = read(root / arm / "public25.json", {})
        official = {r["game_id"]: r for r in aggregate.get("games", []) if r.get("verdict") != "PENDING"}
        entries = []
        for game in pin["game_ids"]:
            case = root / arm / game
            key = f"{arm}/{game}"
            launch = launcher.get("submitted", {}).get(key, {})
            tag = sha256(str(root).encode()).hexdigest()[:12]
            name = launch.get("unit") or f"pub25-{tag}-{arm}-{game.split('-')[0]}"
            unit = name + ".service"
            units.add(unit)
            row = official.get(game) or read(case / "grade/runner-result.json", {})
            active_attempt = row.get("selected_attempt", "original")
            attempts = {}
            for label, path in (("original", case), ("transport-retry", case / "transport-retry")):
                if label != "original" and not path.is_dir():
                    continue
                public = path / "public"
                supervised = read(public / "supervision.json", {})
                scope = supervised.get("scope")
                if scope:
                    units.add(scope)
                stats = receipt_counts(public, game, row if label == active_attempt else {})
                solver = found.get((scope, str(public), str(Path(pin["root"]) / "scripts/run.jl")), [])
                attempts[label] = dict(**stats, supervisor_scope=scope, solver_processes=solver)
            entries.append(dict(game=game, unit=unit, assigned_cpu=plan.get("cpu_assignment", {}).get(key),
                                attempts=attempts))
        groups[arm] = (pin, entries)
    states, error = query(units)
    report["systemd_sample_end_utc"] = timestamp()
    report["affinity_definition"] = ("live_games_matching_cpu and distinct_live_assigned_cpus count tasks whose "
        "affinity-adjustable threads all match the assigned CPU. The all-thread fields include PF_NO_SETAFFINITY "
        "threads. Unknown flags prevent a positive adjustable-thread result. Helper cpu_ticks are cumulative.")

    if error:
        report["systemd_query_error"] = error
    for arm, (pin, entries) in groups.items():
        summary = Counter()
        active_cpus = set()
        all_thread_cpus = set()
        for e in entries:
            e["service"] = states.get(e["unit"])
            rows = list(e["attempts"].values())
            for row in rows:
                scope = row["supervisor_scope"]
                if scope:
                    row["scope_state"] = (states.get(scope) or {}).get("ActiveState", "unknown")
            live = [p for r in rows for p in r["solver_processes"]]
            peaks = [r["peak"] for r in rows if r["peak"] is not None]
            counts = dict(confirmed_resets=sum(r["reset"] for r in rows), confirmed_actions=sum(r["action"] for r in rows),
                          peak_levels=max(peaks, default=None), verified_win=any(r["verified_win"] for r in rows))
            e.update(counts)
            assigned = e["assigned_cpu"]
            all_masks = {mask for p in live for mask in p["thread_masks"]}
            adjustable_masks = {mask for p in live for mask in p["adjustable_thread_masks"]}
            unknown = sum(len(p["unknown_class_threads"]) for p in live)
            if any(p["unreadable_thread_masks"] for p in live):
                all_masks.add(None)
            if unknown or any(p["unreadable_adjustable_masks"] for p in live):
                adjustable_masks.add(None)
            all_match = masks_match(all_masks, assigned)
            user_match = masks_match(adjustable_masks, assigned)
            if user_match is True:
                active_cpus.add(assigned)
            if all_match is True:
                all_thread_cpus.add(assigned)
            wide_protected = [t["tid"] for p in live for t in p["protected_threads"]
                              if t["mask"] is not None and ("," in t["mask"] or "-" in t["mask"])]
            e["affinity"] = dict(adjustable_threads_match=user_match, all_threads_match=all_match,
                                 unknown_class_threads=unknown, wide_mask_protected_tids=wide_protected)
            summary.update(dict(active_case_services=(e["service"] or {}).get("ActiveState") == "active", live_solver_games=bool(live),
                                live_solver_pids=len(live), live_games_matching_cpu=user_match is True,
                                live_games_all_threads_matching_cpu=all_match is True,
                                live_games_adjustable_mask_unknown=bool(live) and user_match is None,
                                live_games_all_masks_unknown=bool(live) and all_match is None,
                                wide_mask_protected_threads=len(wide_protected), unknown_class_threads=unknown, games_with_reset=counts["confirmed_resets"]>0,
                                games_with_action=counts["confirmed_actions"]>0, confirmed_resets=counts["confirmed_resets"],
                                confirmed_actions=counts["confirmed_actions"], peak_levels_sum=counts["peak_levels"] or 0,
                                verified_wins=counts["verified_win"], games_with_evidence_errors=any(r.get("unreadable_evidence") for r in rows)))
        summary.update(distinct_matching_cpu_count=len(active_cpus), distinct_all_thread_matching_cpu_count=len(all_thread_cpus))
        report["arms"][arm] = dict(commit=pin["commit"], games=len(entries), summary=dict(summary),
                                   distinct_live_assigned_cpus=sorted(active_cpus),
                                   distinct_live_all_thread_cpus=sorted(all_thread_cpus), cases=entries)
    report["sample_ended_utc"] = timestamp()
    return report


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("run", type=Path)
    args = ap.parse_args()
    print(json.dumps(snapshot(args.run.resolve()), ensure_ascii=False, indent=2))
