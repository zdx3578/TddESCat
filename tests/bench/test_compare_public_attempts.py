from hashlib import sha256
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import TestCase

from scripts.compare_public_attempts import compare_attempts, same_role


class PublicAttemptComparison(TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.left, self.right = [Path(temp.name) / x for x in ("left", "right")]
        self.before = [[0, 0, 1]]
        self.after = [[0, 0, 2]]
        self.write = dict(
            writer_event="right-c2", kind="role_support", output_port=1, action=None
        )
        for path in (self.left, self.right):
            for directory in ("events", "blobs", "checks", "decisions"):
                (path / directory).mkdir(parents=True)

    def step(
        self,
        path,
        n,
        action,
        frames,
        *,
        decision=None,
        check=None,
        level=0,
        state="NOT_FINISHED",
    ):
        parent = f"{path.name}-c{n - 1}" if n > 1 else None
        ref = f"{path.name}-c{n}"
        act = {"id": action}
        response = dict(
            action_input=act,
            frame=frames,
            available_actions=[1, 2],
            state=state,
            levels_completed=level,
            full_reset=n == 1,
            game_id="controlled",
            win_levels=1,
        )
        raw = json.dumps(response).encode()
        digest = sha256(raw).hexdigest()
        (path / "blobs" / digest).write_bytes(raw)
        name = f"c{n}.json"
        event = dict(
            event_id=ref,
            before_ref=parent,
            response_blob=digest,
            completion="confirmed",
            action=act,
            command_ref=f"c{n}",
            frame_count=len(frames),
            frame_shapes=[[len(f), len(f[0])] for f in frames],
        )
        (path / "events" / (ref + ".json")).write_text(json.dumps(event))
        if decision is not None:
            (path / "decisions" / name).write_text(
                json.dumps(dict(action=act, before_ref=parent, **decision))
            )
        if check is not None:
            (path / "checks" / name).write_text(
                json.dumps(dict(action=act, event_ref=ref, **check))
            )

    def differing_choices(self):
        for path in (self.left, self.right):
            self.step(path, 1, 0, [self.before])
        self.step(self.left, 2, 1, [self.before])
        self.step(
            self.right,
            2,
            2,
            [self.after],
            decision={},
            check={
                "evidence": {"effects": [{"family": "pigment", "after": [[2, 0, 2]]}]},
                "public_relation_feedback": {
                    "fact_flow": {"established": [self.write]}
                },
            },
        )

    def test_traces_prediction_and_animation_invalidation(self):
        self.differing_choices()
        read = dict(**self.write, usage="task_read")
        physical = dict(**self.write, usage="observed_input")
        self.step(
            self.right,
            3,
            1,
            [self.before, self.after],
            decision={"public_relation_task": {"fact_reads": [read]}},
            check={
                "public_relation_feedback": {
                    "fact_flow": {
                        "inputs": [read, physical],
                        "confirmed_task": {"result": "established"},
                        "invalidated": [dict(**self.write, frame=1)],
                    }
                }
            },
        )
        self.step(self.right, 4, 1, [self.before], level=1, state="WIN")
        report = compare_attempts(self.left, self.right)
        self.assertEqual(report["status"], "first_action_difference")
        self.assertEqual(report["reference"]["missing_checks"], 1)
        branch = report["candidate"]
        self.assertEqual(branch["status"], "WIN")
        self.assertEqual(branch["invalidations"][0]["frame"], 1)
        self.assertEqual(
            [r["declared_before_dispatch"] for r in branch["subsequent_direct_uses"]],
            [True, False],
        )

    def test_rejects_a_read_without_a_decision(self):
        self.differing_choices()
        for usage in ("task_read", "policy_preparation_read", "outcome_preparation_read"):
            with self.subTest(usage=usage):
                self.step(
                    self.right,
                    3,
                    1,
                    [self.after],
                    check={
                        "public_relation_feedback": {
                            "fact_flow": {"inputs": [dict(**self.write, usage=usage)]}
                        }
                    },
                )
                with self.assertRaisesRegex(ValueError, "missing before dispatch"):
                    compare_attempts(self.left, self.right)

    def test_earlier_response_difference_precludes_action_attribution(self):
        self.step(self.left, 1, 0, [self.before, self.after])
        self.step(self.right, 1, 0, [self.after, self.after])
        r = compare_attempts(self.left, self.right)
        self.assertEqual(r["status"], "public_response_difference")
        self.assertIsNone(r["before"])

    def test_public_role_covers_entire_four_connected_region(self):
        self.assertFalse(same_role([[1, 1]], [[0, 0, 1]]))
        self.assertTrue(same_role([[1, 0], [0, 1]], [[0, 0, 1]]))
        self.assertFalse(same_role([[1, 0, 1]], [[0, 0, 1], [2, 0, 1]]))

    def test_empty_attempt_is_unavailable(self):
        with self.assertRaisesRegex(ValueError, "No confirmed receipts"):
            compare_attempts(self.left, self.right)
