"""Cross-check live goal program activation and action feedback against public receipts."""

import json
from collections import defaultdict
from hashlib import sha256

from tests.bench.autonomous_audit import decode_value, locate_role, require, signature
from tests.bench.measurement_audit import receipts, replay_meters, verify_step


def frame_sha(frame):
    return sha256(
        bytes(row[x] for x in range(len(frame[0])) for row in frame)
    ).hexdigest()


def load(file):
    return json.loads(file.read_bytes())


def replay_writes(before, writes, digest):
    result = [row[:] for row in before]
    distinct = set()
    for x, y, old, new in writes:
        require(
            0 <= y < len(before)
            and 0 <= x < len(before[y])
            and before[y][x] == old
            and (x, y) not in distinct,
            "projection_input_pixel",
        )
        distinct.add((x, y))
        result[y][x] = new
    require(frame_sha(result) == digest, "projection_digest")
    return result


def audit_projection_record(claim, feedback, before, response, events, event):
    first = before["frame"][-1]
    actual = response["frame"][-1]
    expected = replay_writes(
        first, claim["projected_writes"], claim["projected_sha256"]
    )
    replay_writes(first, claim["base_writes"], claim["base_sha256"])
    require(
        feedback["contract"] == claim["contract"]
        and feedback["version"] == claim["version"]
        and feedback["observed_sha256"] == frame_sha(actual)
        and all(
            events[ref][0]["sequence"] < event["sequence"]
            for ref in [claim["rule_training_event"], *claim["condition_reads"]]
        ),
        "projection_witness",
    )
    valid = len(expected) == len(actual) and len(expected[0]) == len(actual[0])
    delta = (
        [
            [x, y, old, new]
            for y, (a, b) in enumerate(zip(expected, actual, strict=True))
            for x, (old, new) in enumerate(zip(a, b, strict=True))
            if old != new
        ]
        if valid
        else []
    )
    writes = set(map(tuple, claim["writes"]))
    changed = any(
        before.get(key) != response.get(key)
        for key in ("state", "levels_completed", "win_levels", "available_actions")
    )
    require(
        feedback["dimensions_match"] == valid
        and feedback["inside_writes"]
        == [row for row in delta if tuple(row[:2]) in writes]
        and feedback["outside_writes"]
        == [row for row in delta if tuple(row[:2]) not in writes]
        and feedback["matching"] == (valid and not delta and not changed),
        "projection_observed_difference",
    )


def audit_live_goal_programs(public):
    events = receipts(public)
    meters = replay_meters(events)
    publications = {
        data["publication"]: (path.parent, data)
        for path in (public / "learning").glob("job-*/program-publication.json")
        if (data := load(path))["available_after"] is not None
    }
    uses, pending, errors, dispositions, relation_uses = [], [], [], [], []
    next_event = {
        event["before_ref"]: ref
        for ref, (event, _) in events.items()
        if event["before_ref"] is not None
    }
    by_definition = defaultdict(set)
    audited = {}
    for ref, (event, response) in events.items():
        if not response["action_input"]["id"]:
            if pending:
                dispositions.append(
                    {"first": pending[0]["event"], "last": ref, "status": "reset"}
                )
            pending = []
            continue
        command = event["command_ref"]
        path = public / "checks" / (command + ".json")
        if not path.is_file():
            pending = []
            continue
        check = load(path)
        program = check.get("program")
        try:
            decision = load(public / "decisions" / (command + ".json"))
            before_response = events[event["before_ref"]][1]
            if (claim := decision.get("projection")) is not None:
                audit_projection_record(
                    claim, check["projection"], before_response, response, events, event
                )
            if not program:
                require(not pending, "program_continuation_without_disposition")
                continue
            feedback = program["feedback"]
            if feedback == "withdrawn_before_unproved_step":
                require(
                    pending
                    and pending[-1]["definition"] == program["definition"]
                    and pending[-1]["event"] == event["before_ref"]
                    and program["index"] == len(pending) + 1
                    and program["withdrawn_suffix"]
                    == list(range(program["index"], program["length"] + 1)),
                    "program_withdrawn_before_step",
                )
                dispositions.append(
                    {"first": pending[0]["event"], "last": ref, "status": feedback}
                )
                pending = []
                continue
            proof = program["goal"]
            require(
                proof["contract"]
                in ("observed_route_waypoint", "establishes_contact_precondition"),
                "program_goal_contract",
            )
            require(
                decision["reason"] == "revalidated_learned_program",
                "program_choice_reason",
            )
            require(
                decision["candidates"][0]["action"] == program["ordinary_action"],
                "program_ordinary_choice",
            )
            require(
                event["action"] == decision["action"] == check["action"],
                "program_action",
            )
            before = events[event["before_ref"]][0]["sequence"]
            job, activation = publications[program["publication"]]
            require(
                program["available_after"] == activation["available_after"],
                "program_activation_event",
            )
            cut = events[activation["available_after"]][0]["sequence"]
            require(cut <= before < event["sequence"], "program_future_activation")
            require(
                set(program["training_events"]) | {program["available_after"]}
                <= set(check["read_events"])
                and all(
                    events[source][0]["sequence"] <= cut
                    for source in program["training_events"]
                ),
                "program_training_prefix",
            )
            definition = program["definition"]
            if program["publication"] not in audited:
                submitted = load(job / "program-submission.json")
                verified = load(job / "program-verification.json")
                output = load(
                    public / "publication" / (program["publication"] + ".json")
                )
                scope = load(job / "sequence-corpus.json")
                input_manifest = (job / "input/manifest.json").read_bytes()
                manifest = json.loads(input_manifest)
                scopes = [row["events"] for row in scope["scopes"]]
                require(
                    output["input_sha256"]
                    == activation["input_sha256"]
                    == verified["input_sha256"]
                    == sha256(input_manifest).hexdigest()
                    and activation["snapshot"]
                    == verified["snapshot"]
                    == submitted["snapshot"]
                    == manifest["evidence_snapshot_id"]
                    and set(submitted["evidence"]) == set().union(*scopes)
                    and all(
                        events[source][0]["sequence"] <= cut
                        for source in submitted["evidence"]
                    )
                    and output["semantic_context"]["intent"] == "program",
                    "program_verified_publication",
                )
                audited[program["publication"]] = (
                    set(output["definition_depths"]),
                    scopes,
                )
            known, scopes = audited[program["publication"]]
            require(
                definition in known
                and definition in check["definition_refs"]
                and any(
                    any(
                        seq[i : i + len(program["training_events"])]
                        == program["training_events"]
                        for i in range(len(seq))
                    )
                    for seq in scopes
                ),
                "program_structural_witness",
            )
            expected = proof["steps"][0]
            require(
                expected["action"] == check["action"]
                and expected["queries"] == check["expected"],
                "program_projected_successor",
            )
            if claim is not None:
                require(
                    claim["status"] in ("witnessed_base", "conditioned_projection")
                    and claim["projected_sha256"] == expected["frame_sha256"],
                    "program_projection_applicable",
                )
            verify_step(check["evidence"], meters[ref])
            meter_refs = sorted(
                k.removeprefix("measurement-")
                for k in check["assessments"]
                if k.startswith("measurement-")
            )
            require(set(meter_refs) <= meters[ref].keys(), "program_measurement_effect")
            require(
                program["index"] == len(pending) + 1, "program_steps_not_contiguous"
            )
            if pending:
                require(
                    pending[-1]["definition"] == definition
                    and pending[-1]["event"] == event["before_ref"],
                    "program_steps_not_contiguous",
                )
            pending.append(
                {
                    "event": ref,
                    "definition": definition,
                    "level": response["levels_completed"] + 1,
                    "selected": check["action"],
                    "ordinary": program["ordinary_action"],
                    "baseline": program["baseline_action"],
                    "measurements": meter_refs,
                }
            )
            exact = expected["frame_sha256"] == frame_sha(response["frame"][-1])
            supported = set(check["assessments"].values()) == {"supported"}
            if feedback in ("advance", "completed"):
                require(exact and supported, "program_feedback")
            else:
                require(
                    feedback
                    in (
                        "goal_projection_refuted",
                        "effect_refuted_or_unknown",
                        "post_queries_unresolved",
                        "output_binding_unproved",
                    )
                    and program["withdrawn_suffix"]
                    == list(range(program["index"] + 1, program["length"] + 1)),
                    "program_failed_step_disposition",
                )
                if feedback == "goal_projection_refuted":
                    require(
                        not exact
                        or claim is not None
                        and not check["projection"]["matching"],
                        "program_projection_refutation",
                    )
                elif feedback == "effect_refuted_or_unknown":
                    require(not supported, "program_effect_refutation")
                elif feedback == "post_queries_unresolved":
                    require(
                        not check["evidence"]["complete"]
                        or check["evidence"]["residual"],
                        "program_unresolved_post_queries",
                    )
                dispositions.append(
                    {
                        "first": pending[0]["event"],
                        "last": ref,
                        "status": feedback,
                        "withdrawn_suffix": program["withdrawn_suffix"],
                    }
                )
                pending = []
                continue
            if feedback == "completed":
                dispositions.append(
                    {"first": pending[0]["event"], "last": ref, "status": feedback}
                )
                require(
                    locate_role(response["frame"][-1], proof["role"])
                    == tuple(proof["target"])
                    and len(proof["steps"]) == 1,
                    "program_did_not_establish_waypoint",
                )
                if proof["contract"] == "establishes_contact_precondition":
                    regression = proof["regression"]
                    target = regression["binding"]
                    contact = regression["contact"]
                    require(
                        regression["established"] == ["admissible_contact_binding"]
                        and contact["point"] == target["point"]
                        and target["origin"] == proof["target"]
                        and target["action"] in response["available_actions"]
                        and set(regression["reads"]) <= set(check["read_events"])
                        and decode_value(response["frame"][-1], contact["field"])
                        == contact["context"]
                        and decode_value(
                            response["frame"][-1], contact["site"]["field"]
                        )
                        == contact["site"]["value"]
                        and contact["conditions"]["judgment"] == "admitted"
                        and contact["conditions"]["signature"]
                        == signature(contact["context"], contact["site"]["value"]),
                        "regressed_contact_witness",
                    )
                    following = next_event.get(ref)
                    consumed = None
                    if following is not None:
                        later, _ = events[following]
                        candidate = public / "checks" / (later["command_ref"] + ".json")
                        if candidate.is_file():
                            followup = load(candidate).get("contact_feedback")
                            if (
                                followup
                                and followup["point"] == target["point"]
                                and later["action"]["id"] == target["action"]
                            ):
                                require(
                                    followup["outcome"] in ("entered", "progress")
                                    and (
                                        contact["progress"]["judgment"] != "progress"
                                        or followup["outcome"] == "progress"
                                    ),
                                    "regressed_contact_feedback",
                                )
                                consumed = dict(
                                    event=following, outcome=followup["outcome"]
                                )
                    relation_uses.append(
                        dict(
                            event=ref,
                            first=pending[0]["event"],
                            level=pending[0]["level"],
                            binding=target,
                            body=regression["body"],
                            consumed=consumed,
                            baseline_choice_changed=any(
                                s["selected"] != s["baseline"] for s in pending
                            ),
                        )
                    )
                if len(pending) > 1 and any(step["measurements"] for step in pending):
                    uses.append({"waypoint": proof["target"], "steps": pending})
                    identities = {
                        meter for step in pending for meter in step["measurements"]
                    }
                    by_definition[definition].add(
                        (pending[0]["level"], frozenset(identities))
                    )
                pending = []
        except (AssertionError, OSError, KeyError, TypeError, ValueError) as error:
            errors.append({"event": ref, "error": str(error)})
            pending = []
    if pending:
        dispositions.append(
            {
                "first": pending[0]["event"],
                "last": pending[-1]["event"],
                "status": "end_of_confirmed_evidence",
            }
        )
    return {
        "uses": uses,
        "errors": errors,
        "dispositions": dispositions,
        "relation_uses": relation_uses,
        "ordinary_choice_changed": any(
            step["selected"] != step["ordinary"]
            for use in uses
            for step in use["steps"]
        ),
        "baseline_choice_changed": any(
            step["selected"] != step["baseline"]
            for use in uses
            for step in use["steps"]
        ),
        "cross_level": any(
            len({level for level, _ in bindings}) > 1
            and len({meters for _, meters in bindings}) > 1
            for bindings in by_definition.values()
        ),
    }
