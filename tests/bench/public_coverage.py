from collections import Counter, defaultdict


OBJECT_EFFECT_FOLLOWUP = "extend_observed_object_effect"
PUBLIC_OUTCOME_TASKS = {
    "prepare_public_outcome",
    "establish_outcome_relation",
    "continue_outcome_preparation",
    "continue_outcome_relation",
}


def parameter_key(action):
    action_id = action["id"]
    data = action.get("data", action)
    if action_id == 6:
        x, y = data["x"], data["y"]
        assert type(x) is int and type(y) is int and 0 <= x < 64 and 0 <= y < 64
        return (action_id, x, y)
    return (action_id,)


class PublicCoverage:
    """Count only public opportunities and confirmed observations at the declared scope."""

    def __init__(self):
        self.domains = defaultdict(set)
        self.tested = defaultdict(set)
        self.roles = defaultdict(set)
        self.observations = defaultdict(Counter)
        self.models = defaultdict(Counter)
        self.control = defaultdict(Counter)
        self.scenes = {}
        self.object_followups = Counter()
        self.followup_events = set()

    def context(self, receipt, response):
        key = receipt["event_id"]
        if key not in self.scenes:
            frame = response["frame"][-1]
            pixels = bytes(cell for line in frame for cell in line)
            self.scenes[key] = (
                response["levels_completed"],
                len(frame),
                len(frame[0]),
                pixels,
                tuple(sorted(response["available_actions"])),
                parameter_key(response["action_input"]),
            )
        return self.scenes[key]

    def record_object_followup(self, event, response, decision, relation, advanced):
        arbitration = decision.get("task_arbitration") or {}
        choice = arbitration.get("choice") or {}
        task = decision.get("public_relation_task") or {}
        feedback = relation.get("feedback") or {}
        source = decision.get("intervention") or {}
        counters = self.object_followups
        candidates = {
            parameter_key(candidate["action"])
            for candidate in arbitration.get("candidates", ())
            if candidate["reason"] == OBJECT_EFFECT_FOLLOWUP
        }
        counters["proposed"] += len(candidates)
        dispatched = choice.get("reason") == OBJECT_EFFECT_FOLLOWUP
        legacy = not arbitration and bool(source.get("hypothesis"))
        if dispatched or legacy:
            assert source["probe"] == "representative"
            assert parameter_key(source["action"]) == parameter_key(event["action"])
            if dispatched:
                assert parameter_key(choice["action"]) == parameter_key(event["action"])
            counters["dispatched"] += 1
            counters["advancements"] += advanced
            counters["game_over"] += response["state"] == "GAME_OVER"
            self.followup_events.add(event["event_id"])
            contracts = {row["producer"] for row in task.get("contracts", ())}
            if contracts:
                assert parameter_key(task["action"]) == parameter_key(event["action"])
                counters["with_concrete_contract"] += 1
                judgments = {
                    row["producer"]: row["status"]
                    for row in feedback.get("tests", ())
                    if row["producer"] in contracts
                }
                if "refuted" in judgments.values():
                    counters["effect_refuted"] += 1
                elif contracts == judgments.keys() and set(judgments.values()) == {
                    "established"
                }:
                    counters["effect_supported"] += 1
                else:
                    counters["effect_unresolved"] += 1
            else:
                counters["without_concrete_contract"] += 1
        obligation = task.get("obligation") or {}
        if task.get("intent") in PUBLIC_OUTCOME_TASKS or (
            task.get("intent") == "execute_relation_policy"
            and obligation.get("public_outcome") == "advancement"
        ):
            sources = {obligation.get("preparation")}
            sources.update(row["event"] for row in obligation.get("chain", ()))
            sources.discard(event["event_id"])
            if not sources.isdisjoint(self.followup_events):
                counters["consumed_by_outcome_task"] += 1
                counters["outcome_task_established"] += (
                    feedback.get("result") == "established"
                )
                counters["outcome_task_advanced"] += advanced

    def observe(self, receipt, response):
        if response["state"] in ("GAME_OVER", "WIN"):
            return
        context = self.context(receipt, response)
        for action_id in response["available_actions"]:
            self.domains[action_id].add(context)

    def confirm(self, parent, event, response, decision, check):
        receipt, before = parent
        action = parameter_key(event["action"])
        action_id = action[0]
        assert action_id in before["available_actions"]
        self.tested[action_id].add((self.context(receipt, before), action))
        observed = self.observations[action_id]
        model = self.models[action_id]
        control = self.control[action_id]
        relation = check.get("public_relation_feedback") or {}
        advanced = response["levels_completed"] > before["levels_completed"]
        if binding := relation.get("binding"):
            self.roles[action_id].add(binding["lineage"])
        observed["confirmed"] += 1
        observed["game_over"] += response["state"] == "GAME_OVER"
        observed["advancement"] += advanced
        observed["wins"] += response["state"] == "WIN"
        model["unexplained_changes"] += bool(check["evidence"]["residual"])
        model["unresolved_transition"] += bool(relation.get("unresolved"))
        for judgment in check["assessments"].values():
            model["channel_" + judgment] += 1
        for test in (relation.get("feedback") or {}).get("tests", []):
            model["contract_" + test["status"]] += 1
        if arbitration := decision.get("task_arbitration"):
            control["dispatch_" + arbitration["choice"]["source"]] += 1
            control["changed_arbitration_baseline"] += (
                event["action"] != arbitration["baseline"]["action"]
            )
        operation = decision.get("public_relation_task") or {}
        obligation = operation.get("obligation") or {}
        if isinstance(obligation, dict) and (baseline := obligation.get("baseline")):
            control["changed_task_candidate"] += event["action"] != baseline
        if operation.get("reads"):
            control["witnessed_task"] += 1
            control["established_witnessed_task"] += (
                relation.get("feedback") or {}
            ).get("result") == "established"
        self.record_object_followup(event, response, decision, relation, advanced)

    def report(self):
        available = sorted(set(self.domains) | set(self.tested))
        records = {}
        for action_id in available:
            scope_count = len(self.domains[action_id])
            size = 4096 if action_id == 6 else 1
            tested = len(self.tested[action_id])
            # A terminal observation provides no further action opportunity.
            defined = scope_count * size
            assert tested <= defined
            records[str(action_id)] = {
                "definition": {"contexts": scope_count, "parameters_per_context": size},
                "experiment": {
                    **{
                        field: self.observations[action_id][field]
                        for field in ("confirmed", "game_over", "advancement", "wins")
                    },
                    "tested_context_parameters": tested,
                    "untested_context_parameters": defined - tested,
                    "observed_selection_lineages": len(self.roles[action_id]),
                },
                "model": dict(self.models[action_id]),
                "control": dict(self.control[action_id]),
            }
        return {
            "context_scope": "level_last_frame_available_actions_previous_action",
            "actions": records,
            "object_effect_followups": dict(self.object_followups),
        }
