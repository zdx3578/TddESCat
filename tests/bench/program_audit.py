"""Cross-check live goal program activation and action feedback against public receipts."""

import json
from collections import defaultdict
from hashlib import sha256

from tests.bench.autonomous_audit import locate_role, require
from tests.bench.measurement_audit import receipts, replay_meters, verify_step


def frame_sha(frame):
    return sha256(
        bytes(row[x] for x in range(len(frame[0])) for row in frame)
    ).hexdigest()


def load(file):
    return json.loads(file.read_bytes())


def audit_live_goal_programs(public):
    events = receipts(public)
    meters = replay_meters(events)
    publications = {
        data["publication"]: (path.parent, data)
        for path in (public / "learning").glob("job-*/program-publication.json")
        if (data := load(path))["available_after"] is not None
    }
    uses, pending, errors = [], [], []
    by_definition = defaultdict(set)
    audited = {}
    for ref, (event, response) in events.items():
        if not response["action_input"]["id"]:
            pending = []
            continue
        command = event["command_ref"]
        path = public / "checks" / (command + ".json")
        if not path.is_file():
            pending = []
            continue
        check = load(path)
        program = check.get("program")
        if not program or program.get("feedback") not in ("advance", "completed"):
            pending = []
            continue
        try:
            proof = program["goal"]
            require(
                proof["contract"] == "observed_route_waypoint", "program_goal_contract"
            )
            decision = load(public / "decisions" / (command + ".json"))
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
                and expected["frame_sha256"] == frame_sha(response["frame"][-1])
                and expected["queries"] == check["expected"],
                "program_projected_successor",
            )
            require(
                check["assessments"]
                and set(check["assessments"].values()) == {"supported"},
                "program_feedback",
            )
            verify_step(check["evidence"], meters[ref])
            meter_refs = sorted(
                k.removeprefix("measurement-")
                for k in check["assessments"]
                if k.startswith("measurement-")
            )
            require(set(meter_refs) <= meters[ref].keys(), "program_measurement_effect")
            if program["index"] == 1:
                pending = []
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
            if program["feedback"] == "completed":
                require(
                    locate_role(response["frame"][-1], proof["role"])
                    == tuple(proof["target"])
                    and len(proof["steps"]) == 1,
                    "program_did_not_establish_waypoint",
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
    return {
        "uses": uses,
        "errors": errors,
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
