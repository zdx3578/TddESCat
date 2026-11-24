"""Phase-two accepts only evidence produced by the active learning build."""

import subprocess
import tempfile
import unittest
from hashlib import sha256
from pathlib import Path

from tddesc_tools.contracts import Contracts
from tddesc_tools.run import write_json
from tddesc_tools.suite import learning_source_digest, verified_prerequisite


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
