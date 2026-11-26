"""Check relation tasks against public HTTP receipts from isolated fixtures."""

import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace
import subprocess
import sys

from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import supervise
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tests.bench.check_online import online_config
from tests.bench.measurement_audit import receipts


FIXTURE = """
import numpy as np
from arcengine import ARCBaseGame, Camera, Level, Sprite

class Fixture(ARCBaseGame):
    def __init__(self, seed=0):
        frame = np.zeros((64, 64), dtype=np.int8)
        frame[10:13, 8:11] = 4
        if MODE in ("directions", "restart"):
            frame[10:13, 23:26] = 4
            frame[10:13, 38:41] = 4
        else:
            frame[40:42, 44:46] = 2
        actions = {"delayed": [5, 7], "remote": [5, 6], "directions": [6], "restart": [6]}
        super().__init__(GAME, [Level(sprites=[Sprite(frame, name="board")])],
            camera=Camera(width=64, height=64), available_actions=actions[MODE], seed=seed)

    def on_set_level(self, level):
        self.previous = None
        self.probed = False
        self.hits = 0

    def step(self):
        action = self.action.id.value
        if action == 0:
            self.complete_action()
            return
        pixels = self.current_level.get_sprites_by_name("board")[0].pixels
        if MODE == "delayed":
            if self.previous is not None and self.previous != action:
                pixels[40:42, 44:46] = 7
            self.previous = action
        elif action == 5:
            if self.probed:
                pixels[40:42, 44:46] = 7
        else:
            x, y = (self.action.data[k] for k in ("x", "y"))
            tile = next((u for u in (8, 23, 38) if u <= x < u + 3 and 10 <= y < 13), None)
            if MODE == "remote" and tile == 8:
                self.probed = True
                if pixels[40, 44] == 7:
                    pixels[10:13, 8:11] = 9
                    self.next_level()
            if MODE == "directions" and tile is not None and pixels[y, x] == 4:
                delta = 4 if tile == 8 else -4
                pixels[10:13, tile:tile+3] = 0
                pixels[10:13, tile+delta:tile+delta+3] = 4
            if MODE == "restart":
                if self.hits == 0 and tile != 8:
                    self.next_level()
                elif tile is not None and pixels[y, x] == 4:
                    pixels[10:13, tile:tile+3] = 9
                    self.hits += 1
                    if self.hits == 3:
                        self.lose()
        self.complete_action()
"""


def read(path):
    return json.loads(path.read_bytes())


def capture(
    root,
    runtime,
    config,
    run,
    mode,
    number,
    *,
    fixture=FIXTURE,
    budget=9,
    background_search=True,
    compute=False,
):
    base, revision = f"u{number:03}", f"{number:08x}"
    game = f"{base}-{revision}"
    games = run / "private/games"
    folder = games / game
    folder.mkdir(parents=True)
    write_json(folder / "metadata.json", dict(game_id=game, class_name="Fixture"))
    (folder / "fixture.py").write_text(f"MODE = {mode!r}\nGAME = {game!r}\n{fixture}")
    public = run / "public"
    public.mkdir()
    with environment_server(
        root, runtime, config, games, run / "private/server", run / "environment.log"
    ) as (url, _):
        agent = public / "agent.toml"
        online_config(
            agent,
            root,
            url,
            SimpleNamespace(public_id=game),
            planning=True,
            budget=budget,
            sequences=True,
            batch=8,
            background_search=background_search,
        )
        additions = "autonomous = true\nrelation_goals = true\n"
        if compute:
            additions += (
                "\n[compute]\n"
                f'factor_kernel = "{root / "target/release/factor-kernel"}"\n'
                f'solver_python = "{root / "python/compute/.venv/bin/python"}"\n'
            )
        agent.write_text(agent.read_text() + additions)
        assert supervise(root, agent, public) == 0, (public / "solver.log").read_text()
    return public


def observed_steps(public):
    trace = receipts(public)
    for event, reply in trace.values():
        recorded = read(public / "grounding" / (event["event_id"] + ".json"))
        assert (recorded["event"], recorded["before"]) == (
            event["event_id"],
            event["before_ref"],
        )
        before = trace.get(event["before_ref"])
        previous = None if before is None else before[1]["frame"][-1]
        for index, (raw, regions) in enumerate(
            zip(reply["frame"], recorded["frames"], strict=True)
        ):
            shape = [len(raw), len(raw[0])]
            assert regions["frame"] == index and regions["shape"] == shape
            assert 1 <= regions["regions"] <= shape[0] * shape[1]
            changed = None
            if previous is not None and [len(previous), len(previous[0])] == shape:
                changed = sum(
                    left != right
                    for left_row, right_row in zip(previous, raw, strict=True)
                    for left, right in zip(left_row, right_row, strict=True)
                )
            assert regions["changed_pixels"] == changed
            previous = raw
        if not event["action"]["id"]:
            continue
        command = event["command_ref"] + ".json"
        decision = read(public / "decisions" / command)
        feedback = read(public / "checks" / command)["public_relation_feedback"]
        parent = trace[event["before_ref"]][1]
        assert (
            feedback["event"] == event["event_id"]
            and feedback["before"] == event["before_ref"]
        )
        assert feedback["reached"]["state"] == reply["state"]
        assert decision["task_arbitration"]["choice"]["action"] == event["action"]
        assert event["action"]["id"] in parent["available_actions"]
        task = decision.get("public_relation_task")
        if task:
            prediction = read(public / "predictions" / command)
            assert set(task["reads"]).issubset(prediction["event_reads"])
            assert all(
                trace[ref][0]["sequence"] < event["sequence"] for ref in task["reads"]
            )
        yield event, parent, reply, task, feedback


def verify(mode, public):
    rows = list(observed_steps(public))
    if mode == "delayed":
        first, second = rows[:2]
        assert first[1]["frame"][-1] == first[2]["frame"][-1]
        assert second[3]["intent"] == "test_delayed_effect"
        assert second[3]["obligation"]["prefix"] == first[0]["event_id"]
        assert second[2]["frame"][-1][40][44] == 7
        return [first[0]["event_id"], second[0]["event_id"]]
    if mode == "remote":
        row = next(
            row
            for row in rows
            if (row[3] or {}).get("intent") == "distinguish_changed_context"
        )
        earlier = next(
            old for old in rows if old[0]["event_id"] == row[3]["obligation"]["prior"]
        )
        assert earlier[0]["action"] == row[0]["action"]
        assert earlier[1]["frame"][-1][11][9] == row[1]["frame"][-1][11][9] == 4
        assert earlier[2]["frame"][-1][40][44] == 2 and row[1]["frame"][-1][40][44] == 7
        assert row[2]["state"] == "WIN"
        return [earlier[0]["event_id"], row[0]["event_id"]]
    if mode == "directions":
        row = next(
            row for row in rows if (row[4]["feedback"] or {}).get("result") == "refuted"
        )
        test = next(
            test for test in row[4]["feedback"]["tests"] if test["status"] == "refuted"
        )
        assert list(test["expected"].values()) == [[4, 0]]
        assert list(test["actual"].values()) == [[-4, 0]]
        return [row[0]["event_id"]]
    failed = next(row for row in rows if row[2]["state"] == "GAME_OVER")
    assert failed[4]["feedback"]["result"] == "established"
    assert failed[3]["contracts"][0]["scope"] == "replicated"
    assert failed[4]["failure"]["attribution"] == "unresolved"
    reset = read(next((public / "attempts").glob("*.json")))
    restarted = next(row for row in rows if row[0]["before_ref"] == reset["event"])
    assert reset["prior"] == failed[0]["event_id"] and reset["rebound"]
    assert restarted[3]["intent"] == "revise_failed_trace"
    assert restarted[0]["action"] != rows[0][0]["action"]
    assert restarted[2]["state"] == "WIN"
    return [failed[0]["event_id"], reset["event"], restarted[0]["event_id"]]


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
        return verify(mode, directory / "public")

    modes = ("delayed", "remote", "directions", "restart")
    with ThreadPoolExecutor(max_workers=len(modes)) as pool:
        cases = {
            mode: pool.submit(case, number, mode)
            for number, mode in enumerate(modes, 1)
        }
        result = {mode: job.result() for mode, job in cases.items()}
    write_json(run / "public/unified-relations.json", result)
    append_assertion(
        run, "public_relation_feedback_loop", True, ["public/unified-relations.json"]
    )
    return 0


if __name__ == "__main__":
    if sys.argv[1] == "--case":
        root = Path.cwd()
        config, directory, mode, number, *extra = sys.argv[2:]
        if extra not in ([], ["--compute"]):
            raise ValueError("Expected --compute or no extra option")
        public = capture(
            root,
            runtime_paths(root),
            Path(config),
            Path(directory),
            mode,
            int(number),
            compute=bool(extra),
        )
        if extra:
            verify(mode, public)
            proofs = [
                row["factor_role_proof"]
                for path in (public / "decisions").glob("*.json")
                if "factor_role_proof" in (row := read(path))
            ]
            assert any(
                proof["execution"] == "completed" and proof["value"]["entailed"]
                for proof in proofs
            ), proofs
        raise SystemExit(0)
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
