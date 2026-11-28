"""Compare the same first-level omission decision on two solver checkouts."""

import json
from pathlib import Path
import sys
from unittest.mock import patch

from scripts.compare_public_attempts import compare_attempts
from tests.bench import check_unified_relations as fixture
from tests.bench.check_evidence import solver_process
from tests.bench.measurement_audit import receipts
from tddesc_tools.run import runtime_paths, write_json


def run_case(root, source, path):
    def compare(_, runtime, public, settings, store, **options):
        return solver_process(
            source, runtime, public, settings, "--choice-only", store, **options
        )

    path.mkdir(parents=True)
    with patch.object(fixture, "solver_process", compare):
        public = fixture.capture(
            root,
            runtime_paths(root),
            root / "config/bench_server.toml",
            path,
            "relation-use",
            196,
            budget="unlimited",
        )
    events = list(receipts(public).values())
    assert len(events) == 7
    result = json.loads((public / "choice.json").read_bytes())
    assert result["receipt"] == events[-1][0]["event_id"]
    assert result["choice"]["action"] == events[-1][0]["action"]
    assert [event["action"]["id"] for event, _ in events[:-1]] == [0, 1, 2, 4, 4, 3]
    return result, public


def main(baseline, directory):
    root = Path(__file__).resolve().parents[2]
    old, old_public = run_case(root, baseline, directory / "baseline")
    new, new_public = run_case(root, root, directory / "candidate")
    pair = compare_attempts(old_public, new_public)
    assert pair["status"] == "first_action_difference"
    assert pair["matched"] == {"resets": 1, "actions": 5}
    assert pair["reference"]["first"]["event"] == old["receipt"]
    assert pair["candidate"]["first"]["event"] == new["receipt"]
    assert new["intent"] == "test_preparation_omission"
    report = dict(
        baseline=old,
        candidate=new,
        identical_prefix=sum(pair["matched"].values()),
        changed_action=True,
    )
    write_json(directory / "comparison.json", report)
    print(json.dumps(report))


if __name__ == "__main__":
    main(*(Path(arg).resolve() for arg in sys.argv[1:]))
