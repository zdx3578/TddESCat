from unittest import TestCase

from tests.bench.public_coverage import PublicCoverage


class PublicCoverageTest(TestCase):
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
