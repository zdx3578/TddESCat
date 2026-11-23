import copy
import unittest
from pathlib import Path

from jsonschema import ValidationError

from tddesc_tools.contracts import Contracts


class SchemaContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.contracts = Contracts(Path("protocol/v1"))

    def test_job_files_and_exact_versions(self):
        descriptor = {"path": "input/signature.json", "sha256": "1" * 64, "bytes": 128}
        job = {
            "protocol_version": "tddescat.learn.v1",
            "codec_version": "typed-free-slots.v1",
            "job_id": "job-1",
            "evidence_snapshot_id": "snapshot-1",
            "library_base_version": "library-0",
            **{
                f"{field}_file": descriptor.copy()
                for field in (
                    "signature",
                    "programs",
                    "origins",
                    "initial_library",
                    "rules",
                    "config",
                )
            },
            "program_count": 0,
            "slot_context": [],
            "engine_pin": {
                "upstream_commit": "2" * 40,
                "source_git_tree": "3" * 40,
                "cargo_lock_sha256": "4" * 64,
                "rust_version": "1.90.0",
                "build_sha256": "5" * 64,
                "binary_sha256": "6" * 64,
                "protocol_version": "tddescat.learn.v1",
            },
        }
        self.contracts.validate("learn_job", job)
        for path in ("/tmp/config", "../config", "a/../config", "a/./config", "a//b"):
            with self.subTest(path=path), self.assertRaises(ValidationError):
                modified = copy.deepcopy(job)
                modified["config_file"]["path"] = path
                self.contracts.validate("learn_job", modified)
        with self.assertRaises(ValidationError):
            self.contracts.validate(
                "learn_job", {**job, "endpoint": "http://localhost"}
            )
        with self.assertRaises(ValidationError):
            self.contracts.validate("learn_job", {**job, "codec_version": "other"})

    def test_definition_body_can_use_parameters_but_not_free_slots(self):
        definition = {
            "temporary_name": "fn_0",
            "arity": 1,
            "parameter_sorts": ["Delta"],
            "result_sort": "Delta",
            "parameter_reads": [0],
            "body": {
                "kind": "Call",
                "operator": "copy",
                "args": [{"kind": "Param", "index": 0}],
            },
            "pattern_text": "(copy ?#0)",
            "closed_lambda_text": "(lam (copy $0))",
            "dependencies": [],
            "body_cost": "2",
        }
        self.contracts.validate("definition", definition)
        definition["body"]["args"][0]["kind"] = "Slot"
        with self.assertRaises(ValidationError):
            self.contracts.validate("definition", definition)

    def test_click_coordinates_and_exploration_prediction(self):
        prediction = {
            "schema_version": 1,
            "model_version": None,
            "binding": [],
            "action": {"id": 6, "x": 63, "y": 0},
            "guard_truth": "unknown",
            "query_scope": [],
            "predicted_values": {},
            "enumeration_complete": False,
            "assumptions": ["exploration"],
            "created_before_command": {"command_id": "c0002", "sequence": 2},
        }
        self.contracts.validate("prediction", prediction)
        for action in (
            {"id": 6, "x": 64, "y": 0},
            {"id": 6, "x": True, "y": 0},
            {"id": 1, "x": 0},
        ):
            with self.subTest(action=action), self.assertRaises(ValidationError):
                self.contracts.validate("prediction", {**prediction, "action": action})

    def test_acceptance_cannot_hide_missing_required_fields(self):
        item = {
            "schema_version": 1,
            "run_id": "fixture-001",
            "suite_id": "fixtures",
            "status": "PASS",
            "evidence_scope": "environment",
            "tasks": [
                {
                    "id": "M01",
                    "status": "PASS",
                    "assertion_refs": ["grade/assertions.jsonl"],
                    "reason": None,
                }
            ],
        }
        self.contracts.validate("acceptance", item)
        del item["tasks"][0]["assertion_refs"]
        with self.assertRaises(ValidationError):
            self.contracts.validate("acceptance", item)


if __name__ == "__main__":
    unittest.main()
