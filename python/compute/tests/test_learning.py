import math
import unittest

from tddesc_compute.circuit_adapter import query_model, train
from tddesc_compute.history_adapter import learn_history
from tddesc_compute.solver_adapter import synthesize_guard


class ComputeLearningTest(unittest.TestCase):
    def test_circuit_mask_and_resume(self):
        data = {
            "dimensions": [2, 2],
            "units": 2,
            "steps": 12,
            "seed": 19,
            "samples": [
                {"event": str(i), "values": [[0, 0], [1, 1], [0, None]][i % 3]}
                for i in range(15)
            ],
        }
        data["samples"].append(data["samples"][0])
        fitted = train(data)
        self.assertEqual(fitted["status"], "fitted")
        self.assertEqual(fitted["sample_count"], 15)
        rows = query_model(
            {
                "artifact": fitted["artifact"],
                "target": 1,
                "evidence": [[0, None], [1, None], [None, None]],
            }
        )["rows"]
        for row in rows:
            self.assertEqual(row["status"], "supported")
            self.assertTrue(math.isclose(sum(row["probabilities"]), 1, rel_tol=1e-6))
        resumed = train({**data, "steps": 4, "resume": fitted})
        single = train({**data, "steps": 16})
        self.assertEqual(resumed["artifact"], single["artifact"])

    def test_compound_guard(self):
        result = synthesize_guard(
            {
                "features": ["x", "y"],
                "samples": [
                    {"features": [x, y], "expected": x != y}
                    for x in [False, True]
                    for y in [False, True]
                ],
            }
        )
        self.assertEqual(result["status"], "solution")
        self.assertIn(result["guard"]["op"], {"and", "or", "not"})

    def test_mealy_prefix_and_missing_transition(self):
        def episode(index, inp, values):
            return {
                "origin": "same-public-start",
                "steps": [
                    {"event": f"{index}.{i}", "input": a, "output": b}
                    for i, (a, b) in enumerate(zip(inp, values, strict=True))
                ],
            }

        result = learn_history(
            {
                "episodes": [
                    episode(1, ["press", "release"], ["unchanged", "changed"]),
                    episode(2, ["release"], ["unchanged"]),
                ]
            }
        )
        self.assertEqual(result["status"], "learned")
        initial = result["edges"][str(result["initial"])]
        self.assertEqual(initial["release"]["output"], "unchanged")
        other = result["edges"][str(initial["press"]["state"])]
        self.assertEqual(other["release"]["output"], "changed")
        self.assertNotIn("press", other)


if __name__ == "__main__":
    unittest.main()
