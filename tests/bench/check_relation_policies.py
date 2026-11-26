"""Follow candidate provenance, E-Stitch proofs and live policy dispatches."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess
import sys

from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_unified_relations import capture, observed_steps, read
from tests.bench.measurement_audit import receipts
from tests.bench.policy_audit import TrajectoryPolicyAudit


FIXTURE = """
import numpy as np
from arcengine import ARCBaseGame, Camera, Level, Sprite

class Fixture(ARCBaseGame):
    def __init__(self, seed=0):
        frame = np.zeros((64, 64), dtype=np.int8)
        frame[12:16, 16:20] = 4
        if MODE == "branched":
            frame[38:41, 40:43] = 2
        if MODE == "repeat":
            frame[12:16, 32:36] = 4
        super().__init__(GAME, [Level(sprites=[Sprite(frame, name="board")])],
            camera=Camera(width=64, height=64),
            available_actions=[6] if MODE == "repeat" else [5, 6, 7], seed=seed)

    def on_set_level(self, level):
        self.cycles = 0

    def step(self):
        action = self.action.id.value
        pixels = self.current_level.get_sprites_by_name("board")[0].pixels
        if MODE == "repeat":
            self.repeat_step(action, pixels)
            self.complete_action()
            return
        shade = int(pixels[12, 16])
        click = False
        if action == 6:
            x, y = (self.action.data[k] for k in ("x", "y"))
            click = 16 <= x < 20 and 12 <= y < 16
        if shade == 4 and action == 5:
            pixels[12:16, 16:20] = 9
            if MODE == "sequence":
                pixels[22:25, 35:38] = 11
        elif shade == 9:
            if MODE == "sequence" or pixels[38, 40] == 3:
                advance = click
            else:
                advance = action == 7
            if advance:
                pixels[12:16, 16:20] = 10
        elif shade == 10 and action == (7 if MODE == "sequence" else 5):
            pixels[12:16, 16:20] = 4
            if MODE == "sequence":
                pixels[22:25, 35:38] = 0
            else:
                pixels[38:41, 40:43] = 5 - pixels[38, 40]
            self.cycles += 1
            if self.cycles == 19:
                self.next_level()
        self.complete_action()

    def repeat_step(self, action, pixels):
        positions = (16, 32)
        if action == 6:
            x, y = (self.action.data[k] for k in ("x", "y"))
            for origin in positions:
                if origin <= x < origin + 4 and 12 <= y < 16 and pixels[12, origin] == 4:
                    pixels[12:16, origin:origin+4] = 9
                    self._available_actions = [7]
        elif action == 7:
            for origin in positions:
                if pixels[12, origin] == 9:
                    pixels[12:16, origin:origin+4] = 10
            self._available_actions = [6] if any(pixels[12, u] == 4 for u in positions) else [5]
        elif action == 5:
            for origin in positions:
                pixels[12:16, origin:origin+4] = 4
            self._available_actions = [6]
            self.cycles += 1
            if self.cycles == 12:
                self.next_level()
"""


def audit(public, mode):
    policies = {}
    trace = receipts(public)
    verifier = TrajectoryPolicyAudit(public)
    structures = set()
    for path in sorted((public / "learning").glob("job-*/policy-publication.json")):
        source = read(path.parent / "policy-corpus.json")
        published = read(path)
        structures.update(row["structure"] for row in source["episodes"])
        for policy in published["policies"]:
            if policy["body"].get("structure_source") != "confirmed_task_trajectory":
                continue
            assert policy["body"]["definitions"] and policy["training"]
            policies[policy["publication"], policy["definition"]] = policy
    assert policies, f"No verified trajectory policy in {public}"
    dispatches = []
    for event, parent, reply, task, feedback in observed_steps(public):
        name = event["command_ref"] + ".json"
        decision = read(public / "decisions" / name)
        if not (row := decision.get("relation_policy")):
            continue
        policy = policies[row["publication"], row["definition"]]
        assert row["available_after"] == policy["available_after"]
        assert (
            row["baseline_action"] == decision["task_arbitration"]["baseline"]["action"]
        )
        assert row["changed_action"] == (row["baseline_action"] != event["action"])
        assert task["intent"] == "execute_relation_policy"
        predicted = read(public / "predictions" / name)
        assert set(row["training"]) <= set(predicted["event_reads"])
        outcome = read(public / "checks" / name)["relation_policy_feedback"]
        verifier.verify(row, outcome, event, trace, predicted["event_reads"])
        assert outcome["event"] == event["event_id"]
        assert (
            feedback["feedback"]["result"] == "established"
            or task["obligation"]["wait"]
        )
        dispatches.append(
            dict(
                event=event["event_id"],
                action=event["action"],
                before=parent["frame"][-1][12][16],
                after=reply["frame"][-1][12][16],
                result=outcome["result"],
                changed=row["changed_action"],
                branches=[*row["branches"], *outcome["branches"]],
                structure=row["structure"],
            )
        )
    assert any(row["result"] == "stopped" for row in dispatches), dispatches
    if mode != "repeat":
        assert any(row["changed"] for row in dispatches), dispatches
    if mode == "sequence":
        assert "sequence" in structures and any(
            row["action"]["id"] == 6 for row in dispatches
        )
    elif mode == "branched":
        assert "branch" in structures
        chosen = {
            branch["outcome"]
            for row in dispatches
            for branch in row["branches"]
            if branch["control"] == "branch"
        }
        assert chosen == {True, False}, dispatches
    else:
        assert "repeat" in structures
        chosen = {
            branch["outcome"]
            for row in dispatches
            for branch in row["branches"]
            if branch["control"] == "repeat"
        }
        assert chosen == {True, False}, dispatches
    return dict(structures=sorted(structures), dispatches=dispatches)


def main(config, run):
    root = Path.cwd()
    task, runtime = read_task(config), runtime_paths(root)

    def case(number, mode):
        directory = run / "cases" / mode
        directory.mkdir(parents=True)
        with (directory / "process.log").open("wb") as log:
            subprocess.run(
                [
                    runtime["python"]["executable"],
                    "-m",
                    __spec__.name,
                    "--case",
                    str(task["environment_config"]),
                    str(directory),
                    mode,
                    str(number),
                ],
                stdout=log,
                stderr=subprocess.STDOUT,
                check=True,
            )
        return audit(directory / "public", mode)

    with ThreadPoolExecutor(max_workers=3) as pool:
        cases = {
            mode: pool.submit(case, number, mode)
            for number, mode in enumerate(("sequence", "branched", "repeat"), 11)
        }
        result = {mode: job.result() for mode, job in cases.items()}
    write_json(run / "public/relation-policies.json", result)
    append_assertion(
        run, "public_trajectory_policy", True, ["public/relation-policies.json"]
    )
    return 0


if __name__ == "__main__":
    if sys.argv[1] == "--case":
        root = Path.cwd()
        config, directory, mode, number = sys.argv[2:]
        capture(
            root,
            runtime_paths(root),
            Path(config),
            Path(directory),
            mode,
            int(number),
            fixture=FIXTURE,
            budget=112,
            background_search=False,
        )
        raise SystemExit(0)
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
