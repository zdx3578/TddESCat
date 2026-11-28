from collections import Counter
import json
from hashlib import sha256
from pathlib import Path
from subprocess import CompletedProcess
from tempfile import TemporaryDirectory
from unittest import TestCase
from unittest.mock import Mock, patch

from scripts import evaluate_public24, evaluate_public25
from tests.bench.public_coverage import PublicCoverage


class PublicCoverageTest(TestCase):
    def test_multiple_live_reads_are_counted_once_per_confirmed_task(self):
        coverage, counts = PublicCoverage(), Counter()
        coverage.followup_events.add("clicked-writer")
        action = {"id": 3}
        event = {"event_id": "target", "action": action}
        reads = [
            {"usage": "policy_preparation_read", "writer_event": "clicked-writer", "output_port": 1},
            {"usage": "policy_preparation_read", "writer_event": "other-writer", "output_port": 2},
        ]
        historical = {"usage": "omission_contrast", "writer_event": "earlier"}
        task = {"action": action, "fact_reads": reads}
        flow = {"inputs": [historical, *reads], "proposed_omissions": [{"isolated": False}]}
        coverage.record_preparation_use(event, task, {"fact_flow": flow}, counts, True)
        self.assertEqual(counts["live_preparation_writers_read"], 2)
        self.assertEqual(counts["tasks_reading_multiple_preparations"], 1)
        self.assertEqual(counts["advancements_after_live_followup_read"], 1)
        self.assertEqual((counts["omission_candidates"], counts["omission_dispatched"]), (1, 0))
        with self.assertRaises(AssertionError):
            coverage.record_preparation_use(event, {"action": action}, {"fact_flow": flow}, Counter(), True)

    def test_history_statistic_separates_action_prefix_from_model_use(self):
        with TemporaryDirectory() as directory:
            public = Path(directory)
            decisions = public / "decisions"
            decisions.mkdir()
            for i, history in enumerate(([[6, 10, 20]], {"changed_action": False}, {"changed_action": True})):
                task = {"obligation": {"history": history}}
                (decisions / f"{i}.json").write_text(json.dumps({"public_relation_task": task}))
            counts = evaluate_public25.backend_receipts(public)
        self.assertEqual((counts["history_dispatches"], counts["history_dispatch_changes"]), (2, 1))

    def test_competing_predictions_report_a_distinguished_effect(self):
        coverage = PublicCoverage()
        action = {"id": 6, "x": 10, "y": 20}
        event = {"event_id": "observed-comparison", "action": action}
        reason = "extend_observed_object_effect"
        dispatch = {"action": action, "reason": reason}
        decision = {
            "intervention": {"action": action, "probe": "representative"},
            "task_arbitration": {"choice": dispatch, "candidates": [dispatch]},
            "public_relation_task": {
                "action": action,
                "contracts": [{"producer": "positive"}, {"producer": "negative"}],
            },
        }
        feedback = {
            "feedback": {
                "tests": [
                    {"producer": "positive", "status": "established"},
                    {"producer": "negative", "status": "refuted"},
                ],
            },
        }
        coverage.record_object_followup(
            event, {"state": "NOT_FINISHED"}, decision, feedback, False
        )
        self.assertEqual(coverage.object_followups["effect_distinguished"], 1)
        self.assertEqual(coverage.object_followups["effect_refuted"], 0)
        self.assertEqual(coverage.object_followups["effect_supported"], 0)

    def test_repeat_receipts_share_one_observed_parameter_binding(self):
        coverage = PublicCoverage()
        reset = {"event_id": "reset"}
        before = {
            "state": "NOT_FINISHED",
            "frame": [[[4]]],
            "levels_completed": 0,
            "available_actions": [1, 6],
            "action_input": {"id": 0, "data": {}},
        }
        coverage.observe(reset, before)
        click = {"id": 6, "x": 10, "y": 20}
        feedback = {
            "evidence": {"residual": [[0, 0]]},
            "assessments": {"pigment": "supported"},
            "public_relation_feedback": {
                "binding": {"lineage": "selected-role"},
                "unresolved": ["unexplained_pixel_changes"],
                "feedback": {
                    "tests": [{"status": "established"}],
                    "result": "established",
                },
            },
        }
        decision = {
            "task_arbitration": {
                "choice": {"source": "relation", "action": click},
                "baseline": {"action": {"id": 1}},
            },
            "public_relation_task": {"reads": ["reset"]},
        }
        for ref in ("experiment-1", "experiment-2"):
            event = {"event_id": ref, "action": click}
            response = {**before, "state": "GAME_OVER"}
            coverage.observe(event, response)
            coverage.confirm((reset, before), event, response, decision, feedback)
        report = coverage.report()["actions"]
        self.assertEqual(report["1"]["experiment"]["confirmed"], 0)
        self.assertEqual(report["1"]["experiment"]["untested_context_parameters"], 1)
        self.assertEqual(
            report["6"]["definition"], {"contexts": 1, "parameters_per_context": 4096}
        )
        experiments = report["6"]["experiment"]
        self.assertEqual(experiments["confirmed"], 2)
        self.assertEqual(experiments["tested_context_parameters"], 1)
        self.assertEqual(experiments["observed_selection_lineages"], 1)
        self.assertEqual(experiments["game_over"], 2)
        self.assertEqual(experiments["wins"], 0)
        self.assertEqual(report["6"]["model"]["channel_supported"], 2)
        self.assertEqual(report["6"]["model"]["unexplained_changes"], 2)
        self.assertEqual(report["6"]["control"]["changed_arbitration_baseline"], 2)

    def test_confirmed_outcome_survives_an_incomplete_action_record(self):
        with TemporaryDirectory() as temporary:
            case = Path(temporary)
            public = case / "public"
            for name in ("events", "blobs", "checks", "decisions"):
                (public / name).mkdir(parents=True)
            (case / "grade").mkdir()
            config = case / "agent.toml"
            config.write_text(
                '[environment]\ngame_id = "fixture"\n'
                '[execution]\nmax_public_commands = "unlimited"\n[learning]\n'
            )
            prior = None
            for sequence, (action, state, levels) in enumerate(
                ((0, "NOT_FINISHED", 0), (1, "NOT_FINISHED", 0), (1, "WIN", 1)),
                start=1,
            ):
                ref = f"event-{sequence}"
                command = f"command-{sequence}"
                response = {
                    "state": state,
                    "frame": [[[sequence]]],
                    "levels_completed": levels,
                    "win_levels": 1,
                    "available_actions": [1],
                    "action_input": {"id": action},
                    "guid": "local-session",
                }
                raw = json.dumps(response).encode()
                digest = sha256(raw).hexdigest()
                (public / "blobs" / digest).write_bytes(raw)
                receipt = {
                    "event_id": ref,
                    "before_ref": prior,
                    "command_ref": command,
                    "response_blob": digest,
                    "action": {"id": action},
                    "completion": "confirmed",
                    "sequence": sequence,
                }
                (public / "events" / f"{ref}.json").write_text(json.dumps(receipt))
                prior = ref
            for name in ("command-2.json", "command-3.json"):
                (public / "decisions" / name).write_text('{"action": {"id": 1}}')
            (public / "checks" / "command-2.json").write_text(
                '{"action": {"id": 1}, "definition_refs": [],'
                ' "assessments": {}, "evidence": {"residual": []}}'
            )
            with (
                patch.multiple(
                    evaluate_public24,
                    offline_capture=Mock(return_value=0),
                    read_task=Mock(return_value={"agent_config": config}),
                    runtime_paths=Mock(return_value={}),
                    julia_command=Mock(return_value=[]),
                    solver_sandbox=Mock(return_value=[]),
                    public_scorecard_win=Mock(return_value=(True, "verified")),
                    write_artifact_index=Mock(),
                ),
                patch.object(
                    evaluate_public24.subprocess,
                    "run",
                    return_value=CompletedProcess([], 0),
                ),
            ):
                result = evaluate_public24.evaluate_one(case)
            self.assertFalse(result["verified"])
            self.assertEqual(result["confirmed_actions"], 2)
            self.assertEqual(result["actions"], 1)
            self.assertEqual(result["peak_levels"], 1)
            self.assertEqual(
                result["advancement"], [{"event": "event-3", "completed": 1}]
            )
            self.assertEqual(
                result["missing_action_records"],
                [{"event": "event-3", "missing": ["feedback"]}],
            )
            observed = result["causal_coverage"]["actions"]["1"]["experiment"]
            self.assertEqual(observed["confirmed"], 2)
            self.assertEqual(observed["feedback_pending"], 1)
            self.assertEqual(observed["wins"], 1)
