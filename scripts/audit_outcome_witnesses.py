"""Locate missing evidence for an archived outcome's adjacent preparation chain."""

import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path

from scripts.check_v13_process import load, public_response, require
from tests.bench.public_coverage import parameter_key


def preparation_diagnosis(outcome, by_event, visits):
    """Follow only facts recorded before this outcome. Report the first broken link."""
    if outcome["action"][0] == 6 and not outcome["appearance"]:
        return {"stop": "unbound_outcome_role", "chain": []}
    chain = []
    current = outcome
    while current["prior"]:
        prep = by_event.get(current["prior"])
        if not prep:
            return {"stop": "missing_preparation_feedback", "chain": chain}
        if (
            prep["after"] != current["context"]
            or prep["attempt"] != outcome["attempt"]
            or prep["level"] != outcome["level"]
            or prep["state"] != "NOT_FINISHED"
            or prep["advanced"]
        ):
            return {"stop": "scope_boundary", "event": prep["event"], "chain": chain}
        gaps = []
        if prep["available"] != outcome["available"]:
            gaps.append("action_domain_changed")
        if not prep["complete"] or prep["residual"]:
            gaps.append("local_effect_uncertain")
        if prep["producer"] is None:
            gaps.append("missing_producer")
        if gaps:
            return {
                "stop": gaps[0],
                "also_missing": gaps[1:],
                "event": prep["event"],
                "residual_pixels": prep["residual"],
                "chain": chain,
            }
        chain.append({"event": prep["event"], "producer": prep["producer"]})
        for earlier in reversed(visits.get((prep["context"], outcome["action"]), ())):
            if (
                earlier["ordinal"] < prep["ordinal"]
                and earlier["state"] == "NOT_FINISHED"
                and not earlier["advanced"]
                and earlier["appearance"] == outcome["appearance"]
            ):
                return {
                    "stop": "witnessed",
                    "chain": chain,
                    "comparison": earlier["event"],
                }
        current = prep
    return {
        "stop": "missing_comparison" if chain else "no_prior_in_scope",
        "chain": chain,
    }


def audit_witnesses(public, witnesses):
    """Recheck the original adjacent-chain model against this attempt's confirmed prefix."""
    identifiers = {w["event"]: w for w in witnesses}
    end = max(int(ref.rsplit("-c", 1)[1]) for ref in identifiers)
    output = []
    visits = defaultdict(list)
    by_event = {}
    missing_relation_records = 0
    past = None
    before = None
    for path in sorted(
        (public / "events").glob("*.json"), key=lambda p: int(p.stem.rsplit("-c", 1)[1])
    ):
        ev = load(path)
        ordinal = ev["sequence"]
        if ordinal > end:
            break
        ref = ev["event_id"]
        require(
            ev["completion"] == "confirmed" and ev["before_ref"] == past,
            f"Broken chain at {ref}",
        )
        after = public_response(public, ev)
        action = parameter_key(ev["action"])
        require(
            action == parameter_key(after["action_input"]),
            f"Receipt action differs at {ref}",
        )
        command = ev["command_ref"] + ".json"
        checks = public / "checks" / command
        if action[0] and not checks.is_file():
            missing_relation_records += 1
        if action[0] and checks.is_file():
            ck = load(checks)
            require(
                ck["event_ref"] == ref and ck["action"] == ev["action"],
                f"Feedback mismatch at {ref}",
            )
            r = ck.get("public_relation_feedback")
            if r is None:
                missing_relation_records += 1
            if r:
                require(
                    r["event"] == ref and r["before"] == past,
                    f"Relation event mismatch at {ref}",
                )
                e = ck["evidence"]
                item = {
                    "ordinal": ordinal,
                    "event": ref,
                    "prior": r["prior"],
                    "attempt": r["attempt"],
                    "level": before["levels_completed"],
                    "state": after["state"],
                    "advanced": after["levels_completed"] > before["levels_completed"],
                    "available": frozenset(before["available_actions"]),
                    "context": r["context"],
                    "after": r["after"],
                    "action": action,
                    "appearance": (r["binding"] or {}).get("appearance"),
                    "complete": e["complete"],
                    "residual": len(e["residual"]),
                    "producer": (r["producer"] or {}).get("key"),
                }
                by_event[ref] = item
                if ref in identifiers:
                    w = identifiers[ref]
                    require(
                        item["advanced"]
                        and ev["response_blob"] == w["response_sha256"]
                        and after["game_id"] == w["game"],
                        f"Outcome differs at {ref}",
                    )
                    dc = load(public / "decisions" / command)
                    require(
                        dc["action"] == ev["action"] and dc["before_ref"] == past,
                        f"Decision differs at {ref}",
                    )
                    task = dc.get("public_relation_task") or {}
                    recorded = r["public_outcome"]
                    diagnosis = preparation_diagnosis(item, by_event, visits)
                    output.append(
                        {
                            "game": w["game"],
                            "event": ref,
                            "level": after["levels_completed"],
                            "response_sha256": ev["response_blob"],
                            "adjacent_model": diagnosis,
                            "prefix_missing_relation_records": missing_relation_records,
                            "recorded_relationship": recorded["relationship"],
                            "permission_requirements": recorded["requirements"],
                            "ultimate_task": task.get("intent"),
                            "contracts_at_dispatch": len(task.get("contracts", [])),
                            "typed_fact_reads": task.get("fact_reads"),
                            "consumer_evidence": "no_relation_task"
                            if not task
                            else "no_concrete_contract"
                            if not task.get("contracts")
                            else "concrete_contract",
                        }
                    )
                visits[(item["context"], action)].append(item)
        before, past = after, ref
    require(
        {r["event"] for r in output} == set(identifiers),
        f"Missing witness under {public}",
    )
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("runs", type=Path)
    args = parser.parse_args()
    archive = load(args.snapshot)
    groups = defaultdict(list)
    for w in archive["same_revision_one_witness_per_game_level"]:
        case = args.runs / w["run"] / w["game"]
        if w["attempt"] != "original":
            case /= w["attempt"]
        groups[case / "public"].append(w)
    rows = [
        row
        for path, witnesses in groups.items()
        for row in audit_witnesses(path, witnesses)
    ]
    print(
        json.dumps(
            {
                "revision": archive["progress_snapshot"]["revision"],
                "model": "adjacent_preparation_with_nonterminal_comparison",
                "counts": Counter(r["adjacent_model"]["stop"] for r in rows),
                "witnesses": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
