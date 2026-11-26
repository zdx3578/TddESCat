"""Check published policy uses against public task bindings and their prefixes."""

from collections import defaultdict
from hashlib import sha256
import json

from tests.bench.autonomous_audit import require


def read(path):
    return json.loads(path.read_bytes())


def activation_key(row):
    return row["definition"], row["publication"], row["available_after"]


class PolicyAudit:
    def __init__(self, public):
        self.public = public
        self.activations = {
            activation_key(row): (file.parent, record, row)
            for file in (public / "learning").glob("job-*/policy-publication.json")
            if (record := read(file))
            for row in record["policies"]
        }
        self.pending = None
        self.refuted = set()
        self.proofs = {}
        self.uses = []

    def verify(
        self, decision, feedback, ref, before, after, receipts, sites, read_events
    ):
        if decision is None and self.pending is None:
            require(feedback is None, "policy_feedback_without_execution")
            return
        row = self.pending if decision is None else decision
        definition = row["definition"]
        require(definition not in self.refuted, "consumed_withdrawn_policy")
        key = activation_key(row)
        require(key in self.activations, "unknown_policy_activation")
        job, activation, policy = self.activations[key]
        if key not in self.proofs:
            publication = self.public / "publication" / (row["publication"] + ".json")
            require(
                sha256(publication.read_bytes()).hexdigest() == row["publication"],
                "policy_publication_digest",
            )
            bundle = read(publication)
            corpus = read(job / "policy-corpus.json")
            require(
                definition in bundle["definition_depths"]
                and bundle["semantic_context"]["consumer"] == "policy-semantics"
                and bundle["source_programs"] == corpus["programs"]
                and bundle["input_sha256"] == activation["input_sha256"]
                and bundle["input_sha256"]
                == sha256((job / "input/manifest.json").read_bytes()).hexdigest()
                and set(policy["training"]) == set(corpus["events"])
                and len({len(episode["actions"]) for episode in corpus["episodes"]}) > 1
                and any(
                    call["definition_ref"] == definition and not call["call_path"]
                    for call in bundle["calls"]
                ),
                "policy_structural_evidence",
            )
            self.proofs[key] = corpus
        require(
            policy["publication"] == row["publication"] == activation["publication"]
            and policy["available_after"]
            == row["available_after"]
            == activation["available_after"]
            and policy["training"] == row["source"]
            and policy["model"] == row["model"]
            and {activation["available_after"], *policy["training"]} <= receipts.keys()
            and feedback["definition"] == definition
            and feedback["event"] == ref,
            "policy_scope_and_availability",
        )
        if decision is not None:
            require(self.pending is None, "policy_iteration_without_visible_result")
            require(
                {tuple(point) for point in row["targets"]} == set(sites),
                "substituted_policy_domain",
            )
            require(set(row["reads"]) <= read_events, "policy_unreported_reads")
            outcome = dict(policy["body"]["rows"]).get(len(sites))
            expected = (
                "discriminate"
                if outcome is None
                else policy["body"]["positive"]
                if outcome
                else policy["body"]["negative"]
            )
            require(
                row["relation"] == expected, "policy_branch_disagrees_with_evidence"
            )
        result = feedback["result"]
        crossed = after["levels_completed"] > before["levels_completed"]
        require(feedback["advanced"] == crossed, "policy_public_outcome")
        if result == "stopped":
            require(
                decision is not None and row["recheck"] and crossed,
                "premature_policy_stop",
            )
        if result == "awaiting_visible_result":
            require(
                decision is not None and row["recheck"] and not crossed,
                "invalid_policy_iteration",
            )
            self.pending = row
        elif result != "continue":
            self.pending = None
        if result in ("refuted_branch", "invalidated_variant"):
            self.refuted.add(definition)
        self.uses.append(
            dict(
                event=ref,
                definition=definition,
                relation=row["relation"],
                targets=row["targets"],
                status=result,
                level=before["levels_completed"] + 1,
            )
        )


class TrajectoryPolicyAudit:
    def __init__(self, public):
        self.public = public
        self.activations = defaultdict(list)
        for path in (public / "learning").glob("job-*/policy-publication.json"):
            activation = read(path)
            for policy in activation["policies"]:
                if (
                    policy["body"].get("structure_source")
                    == "confirmed_task_trajectory"
                ):
                    self.activations[activation_key(policy)].append(
                        (path.parent, activation, policy)
                    )
        self.proofs = {}

    def verify(self, decision, feedback, event, trace, read_events):
        key = activation_key(decision)
        matches = [
            (job, activation, policy)
            for job, activation, policy in self.activations[key]
            if policy["training"] == decision["training"]
            and policy["body"]["definitions"] == decision["definitions"]
            and policy["body"]["structure"] == decision["structure"]
        ]
        require(bool(matches), "unknown_trajectory_policy_activation")
        job, activation, policy = matches[0]
        proof_key = (job, policy["publication"])
        if proof_key not in self.proofs:
            path = self.public / "publication" / (policy["publication"] + ".json")
            raw = path.read_bytes()
            bundle = json.loads(raw)
            corpus = read(job / "policy-corpus.json")
            require(
                sha256(raw).hexdigest() == policy["publication"]
                and bundle["semantic_context"]["consumer"] == "policy-semantics"
                and bundle["source_programs"] == corpus["programs"]
                and bundle["input_sha256"]
                == activation["input_sha256"]
                == sha256((job / "input/manifest.json").read_bytes()).hexdigest(),
                "trajectory_policy_search_proof",
            )
            self.proofs[proof_key] = (
                corpus["events"],
                {call["definition_ref"] for call in bundle["calls"]},
            )
        events, definitions = self.proofs[proof_key]
        references = {decision["available_after"], *decision["training"]}
        require(
            set(decision["training"]) <= set(events)
            and set(decision["definitions"]) <= definitions
            and references <= set(read_events)
            and all(trace[ref][0]["sequence"] < event["sequence"] for ref in references)
            and feedback["definition"] == decision["definition"]
            and feedback["event"] == event["event_id"],
            "trajectory_policy_scope_and_availability",
        )
