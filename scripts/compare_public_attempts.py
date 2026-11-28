"""Compare two cold public attempts and trace the first divergent action's fact uses."""

import argparse
from collections import Counter
from itertools import zip_longest
import json
from pathlib import Path

from scripts.check_v13_process import load, public_response, require
from tests.bench.public_coverage import parameter_key


def frozen_receipts(public):
    paths = sorted(
        (public / "events").glob("*.json"), key=lambda p: int(p.stem.rsplit("-c", 1)[1])
    )
    require(paths, f"No confirmed receipts in {public}")

    def observations():
        parent = None
        for path in paths:
            event = load(path)
            require(
                event["completion"] == "confirmed" and event["before_ref"] == parent,
                f"Bad prefix: {path}",
            )
            response = public_response(public, event)
            frames = response["frame"]
            require(
                frames
                and len(frames) == event["frame_count"]
                and event["frame_shapes"] == [[len(f), len(f[0])] for f in frames],
                f"Incomplete frames: {path}",
            )
            require(
                parameter_key(event["action"])
                == parameter_key(response["action_input"]),
                f"Bad action: {path}",
            )
            if parent is None:
                require(
                    event["action"]["id"] == 0 and response["levels_completed"] == 0,
                    "Expected cold RESET",
                )
            yield event, response
            parent = event["event_id"]

    return observations()


def same_observation(a, b):
    # GUID and transport identity are new for each attempt. Compare the whole visible transition.
    fields = (
        "game_id",
        "frame",
        "levels_completed",
        "win_levels",
        "state",
        "full_reset",
    )
    return all(a[key] == b[key] for key in fields) and set(
        a["available_actions"]
    ) == set(b["available_actions"])


def read_selected(public, event):
    name = event["command_ref"] + ".json"
    dp, cp = public / "decisions" / name, public / "checks" / name
    decision = load(dp) if dp.exists() else None
    check = load(cp) if cp.exists() else None
    if decision:
        require(
            decision["action"] == event["action"]
            and decision["before_ref"] == event["before_ref"],
            f"Unmatched decision {name}",
        )
    if check:
        require(
            check["action"] == event["action"]
            and check["event_ref"] == event["event_id"],
            f"Unmatched feedback {name}",
        )
    return decision or {}, check or {}


def fact_id(fact):
    return (fact["writer_event"], fact["kind"], fact["output_port"], fact["action"])


def same_role(frame, support):
    """Check that the public frame contains exactly this four-connected component."""
    if not support:
        return False
    points = {(x, y) for x, y, _ in support}
    x, y, color = support[0]
    if any(c != color for _, _, c in support) or not (
        0 <= y < len(frame) and 0 <= x < len(frame[y]) and frame[y][x] == color
    ):
        return False
    todo = [(x, y)]
    visited = {(x, y)}
    while todo:
        x, y = todo.pop()
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if (nx, ny) in visited or not (
                0 <= ny < len(frame)
                and 0 <= nx < len(frame[ny])
                and frame[ny][nx] == color
            ):
                continue
            if (nx, ny) not in points:
                return False
            visited.add((nx, ny))
            todo.append((nx, ny))
    return points == visited


def replay_writes(facts, event, before, response, check):
    active = {}
    for fact in facts:
        key = fact_id(fact)
        require(
            key[0] == event["event_id"] and key not in active, f"Invalid writer {key}"
        )
        require(
            response["state"] == "NOT_FINISHED"
            and before["levels_completed"] == response["levels_completed"],
            f"Out-of-scope write {key}",
        )
        if fact["kind"] == "available_action":
            action = fact["action"]
            require(
                action not in before["available_actions"]
                and action in response["available_actions"],
                f"Unobserved permission gain {key}",
            )
            active[key] = None
        else:
            require(fact["kind"] == "role_support", f"Unknown fact {key}")
            effects = check["evidence"]["effects"]
            port = fact["output_port"]
            require(1 <= port <= len(effects), f"Missing writer effect {key}")
            effect = effects[port - 1]
            require(
                effect["family"] in {"translation", "pigment"}
                and same_role(response["frame"][-1], effect["after"])
                and not same_role(before["frame"][-1], effect["after"]),
                f"Unobserved changed role support {key}",
            )
            active[key] = effect["after"]
    return active


def update_support(active, response, level, domain):
    lost = {}
    for key, role in list(active.items()):
        boundary = (
            response["levels_completed"] != level or response["state"] != "NOT_FINISHED"
        )
        if boundary:
            frame = 1 if role is not None else len(response["frame"])
        elif role is None:
            if key[-1] in response["available_actions"]:
                continue
            frame = len(response["frame"])
        else:
            frame = next(
                (
                    i
                    for i, f in enumerate(response["frame"], 1)
                    if (len(f), len(f[0])) != domain or not same_role(f, role)
                ),
                None,
            )
            if frame is None:
                continue
        lost[key] = frame
        del active[key]
    return lost


def branch_after_choice(public, start, rest, before_response):
    before_level = before_response["levels_completed"]
    event, response = start
    dc, ck = read_selected(public, event)
    choice = (dc.get("task_arbitration") or {}).get("choice")
    task = dc.get("public_relation_task") or {}
    rel = ck.get("public_relation_feedback") or {}
    flow = rel.get("fact_flow")
    created = (flow or {}).get("established", [])
    active = replay_writes(created, event, before_response, response, ck)
    roots = set(active)
    frame = response["frame"][-1]
    domain = len(frame), len(frame[0])
    uses, losses = [], []
    first = {
        "event": event["event_id"],
        "before": event["before_ref"],
        "response_sha256": event["response_blob"],
        "action": event["action"],
        "choice": choice,
        "purpose": task.get("obligation"),
        "intent": task.get("intent"),
        "pre_dispatch_fact_reads": task.get("fact_reads", []),
        "prediction_contracts": task.get("contracts", []),
        "established": created,
        "fact_flow_recorded": flow is not None,
        "task_result": rel.get("feedback"),
        "state": response["state"],
        "level": response["levels_completed"],
    }
    status = "reset" if event["action"]["id"] == 0 else "confirmed_prefix"
    missing = int(not ck and status != "reset")
    missing_decisions = int(not dc and status != "reset")
    observed = event
    while (
        status != "reset"
        and response["state"] == "NOT_FINISHED"
        and response["levels_completed"] == before_level
    ):
        following = next(rest, None)
        if following is None:
            break
        observed, response = following
        if observed["action"]["id"] == 0:
            status = "reset"
            break
        dec, check = read_selected(public, observed)
        missing += int(not check)
        missing_decisions += int(not dec)
        feedback = (check.get("public_relation_feedback") or {}).get("fact_flow") or {}
        declared = (dec.get("public_relation_task") or {}).get("fact_reads", [])
        # Only decision-time reads establish task consumption. After-only recognitions are separate.
        inputs = [f for f in feedback.get("inputs", ()) if fact_id(f) in roots]
        for edge in inputs:
            key = fact_id(edge)
            historical = (
                edge["usage"] == "omission_test"
                and edge.get("scope") == "historical_contrast"
            )
            require(
                key in active or historical,
                f"Read after loss of support at {observed['event_id']}: {key}",
            )
            if edge["usage"] in {"task_read", "policy_preparation_read", "outcome_preparation_read"} or historical:
                require(
                    edge in declared,
                    f"Task read missing before dispatch at {observed['event_id']}",
                )
            uses.append(
                {
                    "event": observed["event_id"],
                    "writer": edge["writer_event"],
                    "kind": edge["kind"],
                    "output_port": edge["output_port"],
                    "public_support_before_dispatch": key in active,
                    "usage": edge["usage"],
                    "declared_before_dispatch": edge in declared,
                    "action": observed["action"],
                    "result": feedback.get("confirmed_task"),
                    "response_sha256": observed["response_blob"],
                }
            )
        lost = update_support(active, response, before_level, domain)
        recorded = [f for f in feedback.get("invalidated", ()) if fact_id(f) in roots]
        if "invalidated" in feedback:
            require(
                {fact_id(f): f["frame"] for f in recorded} == lost,
                f"Public invalidation differs at {observed['event_id']}",
            )
        for key, frame in lost.items():
            losses.append(
                {
                    "writer_event": key[0],
                    "kind": key[1],
                    "output_port": key[2],
                    "action": key[3],
                    "frame": frame,
                    "event": observed["event_id"],
                    "recorded": any(fact_id(f) == key for f in recorded),
                }
            )
    if response["state"] != "NOT_FINISHED":
        status = response["state"]
    elif response["levels_completed"] > before_level:
        status = "advanced"
    return {
        "first": first,
        "subsequent_direct_uses": uses,
        "invalidations": losses,
        "through": observed["event_id"],
        "through_sha256": observed["response_blob"],
        "status": status,
        "level": response["levels_completed"],
        "missing_checks": missing,
        "missing_decisions": missing_decisions,
    }


def compare_attempts(reference, candidate):
    left, right = frozen_receipts(reference), frozen_receipts(candidate)
    common = Counter()
    last = None
    before = None
    for a, b in zip_longest(left, right):
        if a is None or b is None:
            return {
                "status": "common_prefix_only",
                "matched": dict(common),
                "through": last,
                "shorter": "reference" if a is None else "candidate",
            }
        ea, oa = a
        eb, ob = b
        if parameter_key(ea["action"]) != parameter_key(eb["action"]):
            require(last is not None, "Different opening actions")
            return {
                "status": "first_action_difference",
                "matched": dict(common),
                "before": last,
                "reference": branch_after_choice(reference, a, left, before),
                "candidate": branch_after_choice(candidate, b, right, before),
            }
        if not same_observation(oa, ob):
            return {
                "status": "public_response_difference",
                "matched": dict(common),
                "before": last,
                "reference": ea["event_id"],
                "candidate": eb["event_id"],
            }
        before = oa
        common["actions" if ea["action"]["id"] else "resets"] += 1
        last = {
            "reference": ea["event_id"],
            "candidate": eb["event_id"],
            "level": oa["levels_completed"],
        }
    return {
        "status": "identical_observed_prefix",
        "matched": dict(common),
        "through": last,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()
    print(
        json.dumps(
            compare_attempts(args.reference, args.candidate),
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
