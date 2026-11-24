"""Phase-two accepts only evidence produced by the active learning build."""

import subprocess
import tempfile
import unittest
from hashlib import sha256
from pathlib import Path
from unittest.mock import patch

from tddesc_tools.contracts import Contracts
from tddesc_tools.run import write_json
from tddesc_tools.suite import learning_source_digest, run_suite, verified_prerequisite


class PhasePrerequisite(unittest.TestCase):
    def test_build_and_policy_changes_block_old_evidence(self):
        contracts = Contracts(Path("protocol/v1"))
        with tempfile.TemporaryDirectory() as sandbox:
            root = Path(sandbox)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            configs = root / "config/acceptance"
            configs.mkdir(parents=True)
            suite = configs / "phase1.toml"
            suite.write_text("""schema_version = 1
suite_id = "phase1"
artifact_root = "../../runs"
[[tasks]]
id = "structure"
config = "stitch.toml"
required = true
depends_on = []
""")
            (configs / "stitch.toml").write_text("# case\n")
            runtime = root / "python/src/worker.py"
            runtime.parent.mkdir(parents=True)
            runtime.write_text("policy = 2\n")
            policy = root / "config/stitch.toml"
            policy.write_text("max_arity = 1000\n")

            def identity():
                return {
                    "source_sha256": learning_source_digest(root),
                    "policy_sha256": sha256(policy.read_bytes()).hexdigest(),
                }

            report = root / "runs/pass/public/acceptance.json"
            member = root / "runs/pass/tasks/structure/public"
            grade = {
                "schema_version": 1,
                "run_id": "pass",
                "suite_id": "phase1",
                "status": "PASS",
                "evidence_scope": "evidence",
                "tasks": [
                    {
                        "id": "structure",
                        "status": "PASS",
                        "assertion_refs": ["tasks/structure/public/acceptance.json"],
                        "reason": None,
                    }
                ],
            }
            write_json(report, grade)
            write_json(member / "acceptance.json", grade)
            write_json(
                member / "manifest.json", {"fixture": "constructed for identity test"}
            )
            write_json(
                report.with_name("provenance.json"),
                {
                    "learning_build": identity(),
                    "suite_config_sha256": sha256(suite.read_bytes()).hexdigest(),
                    "structure": {
                        f"{name}_sha256": sha256(
                            (member / f"{name}.json").read_bytes()
                        ).hexdigest()
                        for name in ("acceptance", "manifest")
                    },
                },
            )

            def eligible():
                return verified_prerequisite(
                    contracts,
                    configs / "phase2_policy.toml",
                    report,
                    "phase1",
                    identity(),
                )

            self.assertTrue(eligible())
            docs = root / "docs/changelog"
            docs.mkdir(parents=True)
            (docs / "当日报告.md").write_text("# 实验记录\n")
            self.assertTrue(eligible())
            policy.write_text("max_arity = 2000\n")
            self.assertFalse(eligible())
            policy.write_text("max_arity = 1000\n")
            runtime.write_text("policy = 3\n")
            self.assertFalse(eligible())

    def test_verifies_each_stage_with_the_same_build(self):
        with tempfile.TemporaryDirectory() as sandbox:
            root = Path(sandbox)
            configs = root / "config/acceptance"
            configs.mkdir(parents=True)
            (root / "protocol").symlink_to(Path("protocol").resolve())
            case = root / "config/acceptance/case.toml"
            case.write_text(
                'schema_version = 1\nkind = "planning"\noutput_name = "case"\n'
            )

            def execute_case(_root, _path, _config, child, _runtime):
                write_json(child / "public/manifest.json", {"case": "suite-runner"})
                write_json(
                    child / "public/acceptance.json",
                    {
                        "schema_version": 1,
                        "run_id": "single-task",
                        "suite_id": "case",
                        "status": "PASS",
                        "evidence_scope": "evidence",
                        "tasks": [
                            {
                                "id": "case",
                                "status": "PASS",
                                "reason": None,
                                "assertion_refs": ["grade/assertions.jsonl"],
                            }
                        ],
                    },
                )

            names = ("phase1", "phase2_policy", "association_phase", "sequence_phase")
            boundary = ""
            for name in names:
                path = configs / f"{name}.toml"
                path.write_text(f'''schema_version = 1
suite_id = "{name}"
artifact_root = "../../runs"
{boundary}
[[tasks]]
id = "case"
config = "case.toml"
required = true
depends_on = []
''')
                boundary = f'prerequisite_suite = "{name}"'

            prior = None
            with (
                patch(
                    "tddesc_tools.suite.learning_build_identity",
                    return_value={"build": "one"},
                ) as identity,
                patch("tddesc_tools.suite.worktree_digest", return_value="same-source"),
                patch("tddesc_tools.suite.run_task", side_effect=execute_case),
            ):
                for name in names:
                    location = root / "runs" / name
                    config = configs / f"{name}.toml"
                    self.assertEqual(run_suite(root, config, location, {}, prior), 0)
                    if name != "sequence_phase":
                        prior = location / "public/acceptance.json"
                identity.return_value = {"build": "two"}
                self.assertEqual(
                    run_suite(root, config, root / "runs/rejected", {}, prior), 3
                )
