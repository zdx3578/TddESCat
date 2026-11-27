"""Check relation tasks against public HTTP receipts from isolated fixtures."""

import json
from concurrent.futures import ThreadPoolExecutor
from hashlib import sha256
from pathlib import Path
from types import SimpleNamespace
import subprocess
import sys
import tomllib
from unittest.mock import patch

from tddesc_tools import public_run
from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import public_settings, supervise
from tests.bench.check_evidence import solver_process
from tddesc_tools.run import (
    append_assertion,
    julia_command,
    read_task,
    runtime_paths,
    write_json,
)
from tests.bench.check_online import online_config
from tests.bench.measurement_audit import receipts


OUTCOME_POLICY_MODES = ("outcome-policy", "outcome-policy-failure")


FIXTURE = """
import numpy as np
from arcengine import ARCBaseGame, Camera, Level, Sprite

class Fixture(ARCBaseGame):
    def __init__(self, seed=0):
        frame = np.zeros((64, 64), dtype=np.int8)
        frame[10:13, 8:11] = 4
        if MODE == "circuit-role":
            frame[10:13, 38:41] = 11
        if MODE == "bridge-partition":
            frame[10:13, 8:11] = 0
            frame[20, 14:23] = 4
            frame[40, 45] = 2
        elif MODE == "concrete-object-followup":
            frame[10:13, 23:26] = 4
            frame[10:13, 38:41] = 4
            frame[34:37, 8:11] = 2
            frame[34:37, 38:41] = 2
        elif MODE in ("directions", "restart", "restart-choices"):
            frame[10:13, 23:26] = 4
            frame[10:13, 38:41] = 4
        else:
            frame[40:42, 44:46] = 2
        if MODE == "context-reprobe":
            frame[10:13, 23:26] = 4
        if MODE == "effect-scope-exploration":
            frame[10:13, 38:41] = 4
        actions = {"delayed": [5, 7], "remote": [5, 6], "directions": [6],
            "context-reprobe": [5, 6],
            "effect-scope-exploration": [5, 6],
            "restart": [6], "progress-restart": [6], "restart-choices": [6],
            "advancement-transfer": [6], "advancement-refutation": [5, 6], "history-refinement": [1, 4],
            "history-continuation": [1, 4], "history-matrix": [1, 4], "history-receipt": [1, 4], "long-history": [1, 4],
            "outcome-preparation": [5, 7], "outcome-chain": [5, 7], "role-outcome": [5, 6],
            "outcome-policy": [1, 5, 6, 7], "outcome-policy-failure": [1, 5, 6, 7],
            "primitive-outcome": [2, 5], "outcome-relation-chain": [2, 5, 7],
            "bridge-partition": [5], "concrete-object-followup": [5, 6],
            "frontier-dispatch": [1, 2], "policy-yield": [1, 2],
            "frontier-route": [2], "frontier-remote-coordinate": [2],
            "sequence-experiment": [1, 2, 3], "mixed-sequence": [1, 2, 3, 6],
            "circuit-role": [6, 7], "coordinate-restart": [6]}
        if MODE == "outcome-relation-chain":
            frame[50:52, 48:50] = 3
        levels = [Level(sprites=[Sprite(frame.copy(), name="board")])]
        if MODE == "progress-restart":
            frame[10:13, 23:26] = 4
            frame[10:13, 38:41] = 4
            levels.append(Level(sprites=[Sprite(frame, name="board")]))
        if MODE == "advancement-transfer":
            frame[10:13, 8:11] = 3
            frame[10:13, 38:41] = 4
            levels.append(Level(sprites=[Sprite(frame, name="board")]))
        if MODE == "advancement-refutation":
            frame[10:13, 8:11] = 0
            frame[10:13, 38:41] = 4
            levels.append(Level(sprites=[Sprite(frame, name="board")]))
        if MODE in ("outcome-preparation", "outcome-chain", "role-outcome", "primitive-outcome", "outcome-relation-chain"):
            frame[10:13, 8:11] = 0
            frame[10:13, 38:41] = 4
            levels.append(Level(sprites=[Sprite(frame, name="board")]))
        if MODE in ("outcome-policy", "outcome-policy-failure"):
            levels = []
            for left in (8, 38, 23):
                board = frame.copy()
                board[10:13, :] = 0
                board[10:13, left:left+3] = 4
                levels.append(Level(sprites=[Sprite(board, name="board")]))
        super().__init__(GAME, levels,
            camera=Camera(width=64, height=64), available_actions=actions[MODE], seed=seed)

    def on_set_level(self, level):
        self.previous = None
        self.probed = False
        self.hits = 0
        if MODE in ("history-refinement", "history-continuation", "history-matrix", "history-receipt", "long-history"):
            self._available_actions = [1, 4]
        if MODE in ("outcome-preparation", "outcome-chain"):
            self._available_actions = [5, 7]
        if MODE in ("frontier-route", "frontier-remote-coordinate"):
            self._available_actions = [2]

    def handle_reset(self):
        if MODE == "progress-restart" and self._state.name == "GAME_OVER":
            self.full_reset()
        else:
            super().handle_reset()

    def step(self):
        action = self.action.id.value
        if action == 0:
            self.complete_action()
            return
        pixels = self.current_level.get_sprites_by_name("board")[0].pixels
        if MODE == "coordinate-restart":
            if (self.action.data["x"], self.action.data["y"]) == (0, 32):
                self.next_level()
            else:
                self.lose()
        elif MODE == "circuit-role":
            if action == 7:
                pixels[50, 50] = 12
            elif pixels[self.action.data["y"], self.action.data["x"]] == 11:
                pixels[40:42, 44:46] = 7
        elif MODE in ("sequence-experiment", "mixed-sequence"):
            if action == 3 and self.previous == 2 and self.hits >= 7:
                self.next_level()
            else:
                self.hits += 1
                self.previous = action
                pixels[40, 45] = 8 + self.hits % 8
        elif MODE == "frontier-route":
            if action == 2:
                self.hits += 1
                pixels[10, 8] = 5 if self.hits % 2 else 4
                self._available_actions = [1, 2, 3] if self.hits % 2 else [2]
            elif action == 1:
                self.next_level()
        elif MODE == "frontier-remote-coordinate":
            if action == 2:
                pixels[10, 8] = 5
                self._available_actions = [6]
            elif (self.action.data["x"], self.action.data["y"]) == (0, 0):
                self.next_level()
            else:
                self.lose()
        elif MODE in ("frontier-dispatch", "policy-yield"):
            if action == 2:
                self.hits += 1
            elif self.hits >= 2:
                self.next_level()
            else:
                self.lose()
        elif MODE == "bridge-partition":
            if action == 5:
                pixels[20, 18] = 0
                self._available_actions = [6]
            elif pixels[self.action.data["y"], self.action.data["x"]] == 4:
                pixels[20, 18] = 4
                self.next_level()
        elif MODE == "context-reprobe":
            if action == 5:
                self.hits += 1
                pixels[40:42, 44:46] = (7, 2, 8)[self.hits - 1]
            elif pixels[40, 44] == 8 and self.action.data["x"] == 24:
                self.next_level()
        elif MODE == "effect-scope-exploration":
            if action == 5:
                self.hits += 1
                pixels[10:13, 8:11] = 4
                pixels[40, 44] = 5 + self.hits
            elif (self.action.data["x"], self.action.data["y"]) == (9, 11):
                pixels[10:13, 8:11] = 9
            elif self.hits >= 3 and (self.action.data["x"], self.action.data["y"]) == (39, 11):
                pixels[10:13, 38:41] = 9
                self.next_level()
        elif MODE == "role-outcome":
            if action == 5:
                pixels[40:42, 44:46] = 7
            elif pixels[40, 44] == 7 and pixels[self.action.data["y"], self.action.data["x"]] == 4:
                self.next_level()
        elif MODE in ("outcome-policy", "outcome-policy-failure"):
            if action == 5:
                pixels[40:42, 44:46] = 7
            elif action == 7:
                pixels[40:42, 44:46] = 2
            elif action == 6 and pixels[40, 44] == 7 and pixels[self.action.data["y"], self.action.data["x"]] == 4:
                if MODE == "outcome-policy-failure" and self.level_index == 2:
                    self.lose()
                else:
                    self.next_level()
        elif MODE in ("primitive-outcome", "outcome-relation-chain"):
            if action == 5:
                pixels[40:42, 44:46] = 7
            elif action == 7:
                pixels[50:52, 48:50] = 8
            elif action == 2 and pixels[40, 44] == 7 and (
                MODE == "primitive-outcome" or pixels[50, 48] == 8
            ):
                self.next_level()
        elif MODE == "concrete-object-followup":
            if action == 5 and pixels[35, 39] == 7:
                self.next_level()
            elif action == 6:
                x, y = (self.action.data[k] for k in ("x", "y"))
                if 10 <= y < 13 and pixels[y, x] == 4 and pixels[35, x] == 2:
                    left = 8 if x < 11 else 38
                    pixels[34:37, left:left+3] = 7
        elif MODE == "advancement-refutation":
            if action == 5:
                self.next_level()
            elif pixels[self.action.data["y"], self.action.data["x"]] == 4:
                if self.level_index == 0:
                    self.next_level()
                else:
                    self.hits += 1
                    pixels[40:42, 44:46] = 7 + self.hits % 2
        elif MODE in ("outcome-preparation", "outcome-chain"):
            if action == 5:
                self._available_actions = [2] if MODE == "outcome-chain" else [6]
            elif action == 2:
                self._available_actions = [6]
            elif action == 7:
                self.lose()
            elif pixels[self.action.data["y"], self.action.data["x"]] == 4:
                if self.level_index == 1:
                    pixels[10, 38] = 0
                self.next_level()
        elif MODE in ("history-matrix", "history-receipt", "long-history"):
            if action in (1, 4):
                self.previous = action
                self._available_actions = [5]
            elif action == 5:
                if MODE == "long-history" and self.hits < 3:
                    self.hits += 1
                    self.complete_action()
                    return
                if MODE == "history-receipt" and self.hits == 0:
                    self.hits += 1
                    pixels[10:13, 8:11] = self.previous
                    return
                pixels[10:13, 8:11] = 3
                self._available_actions = [2, 7]
            elif action == 2 and self.previous == 4:
                self.next_level()
            elif action == 7 and self.previous == 1:
                self.lose()
        elif MODE in ("history-refinement", "history-continuation"):
            if self.probed:
                self.hits += 1
                if action == 2 and self.hits >= 12:
                    self.next_level()
            elif action in (1, 4):
                self.previous = action
                self._available_actions = [5]
            elif action == 5:
                pixels[10:13, 8:11] = 3
                self._available_actions = [7]
            elif action == 7:
                if self.previous == 1:
                    self.lose()
                elif MODE == "history-continuation":
                    self.probed = True
                    pixels[10:13, 8:11] = 10
                    self._available_actions = [2, 7]
                else:
                    self.next_level()
        elif MODE == "delayed":
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
            if MODE == "progress-restart":
                if self.level_index == 0 or tile in (23, 38):
                    self.next_level()
                elif tile == 8:
                    self.lose()
            if MODE == "restart-choices":
                if tile in (8, 23):
                    self.lose()
                elif tile == 38:
                    self.next_level()
            if MODE == "advancement-transfer" and tile in (8, 38) and pixels[y, x] == 4:
                self.next_level()
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
    fixture_mode = "history-continuation" if mode == "history-dispatch" else mode
    (folder / "fixture.py").write_text(
        f"MODE = {fixture_mode!r}\nGAME = {game!r}\n{fixture}"
    )
    compute_enabled = compute or mode in ("history-dispatch", "circuit-role")
    extended_timeout = compute_enabled or mode in (
        *OUTCOME_POLICY_MODES,
        "outcome-preparation",
        "outcome-chain",
        "role-outcome",
        "primitive-outcome",
        "outcome-relation-chain",
        "bridge-partition",
        "context-reprobe",
        "effect-scope-exploration",
        "frontier-dispatch",
        "policy-yield",
        "frontier-route",
        "frontier-remote-coordinate",
        "history-matrix",
        "history-receipt",
        "long-history",
        "coordinate-restart",
        "advancement-refutation",
        "concrete-object-followup",
        "sequence-experiment",
        "mixed-sequence",
    )
    public = run / "public"
    public.mkdir()
    with environment_server(
        root,
        runtime,
        config,
        games,
        run / "private/server",
        run / "environment.log",
        startup_timeout=120 if extended_timeout else 20,
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
            connect_timeout=15.0 if extended_timeout else 2.0,
            request_timeout=60.0 if extended_timeout else 5.0,
        )
        additions = "autonomous = true\nrelation_goals = true\n"
        if compute_enabled:
            additions += (
                "\n[compute]\n"
                f'factor_kernel = "{root / "target/release/factor-kernel"}"\n'
                f'solver_python = "{root / "python/compute/.venv/bin/python"}"\n'
                f'circuit_python = "{root / "python/compute/.venv/bin/python"}"\n'
            )
        settings = agent.read_text()
        if mode == "history-receipt":
            settings = settings.replace("history_lengths = [0, 1, 2, 4]", "history_lengths = [0, 1]")
        agent.write_text(settings + additions)
        direct_tests = {
            "advancement-refutation": "advancement_refutation_public.jl",
            "concrete-object-followup": "concrete_object_followup_public.jl",
            "history-dispatch": "history_public.jl",
            "circuit-role": "circuit_role_public.jl",
            "coordinate-restart": "coordinate_restart_public.jl",
            "context-reprobe": "context_reprobe_public.jl",
            "effect-scope-exploration": "effect_scope_exploration_public.jl",
            "frontier-dispatch": "frontier_dispatch.jl",
            "policy-yield": "policy_yield_public.jl",
            "frontier-route": "frontier_route_public.jl",
            "frontier-remote-coordinate": "frontier_remote_coordinate_public.jl",
            "history-matrix": "history_matrix_public.jl",
            "history-receipt": "history_matrix_public.jl",
            "long-history": "history_matrix_public.jl",
            "role-outcome": "outcome_relation_public.jl",
            "primitive-outcome": "outcome_relation_public.jl",
            "outcome-relation-chain": "outcome_relation_public.jl",
            "sequence-experiment": "sequence_experiment_public.jl",
            "mixed-sequence": "sequence_experiment_public.jl",
        }
        if mode in OUTCOME_POLICY_MODES:
            script = root / "tests/julia/outcome_policy_public.jl"
            paths = public_settings(root, agent, tomllib.loads(agent.read_text()))
            original = public_run.solver_command

            def outcome_solver(base, toolchain, settings, store, allowed, **options):
                command = julia_command(
                    base, toolchain, script, str(settings), mode, str(store), str(base)
                )
                return original(
                    base,
                    toolchain,
                    settings,
                    store,
                    (*allowed, script),
                    command=command,
                    **options,
                )

            with patch.object(public_run, "solver_command", outcome_solver):
                assert supervise(root, agent, public, expected_paths=paths) == 0, (
                    public / "solver.log"
                ).read_text()
        elif mode in direct_tests:
            name = direct_tests[mode]
            script = root / "tests/julia" / name
            paths = public_settings(root, agent, tomllib.loads(agent.read_text()))
            result = solver_process(
                root,
                runtime,
                public,
                str(agent),
                *([mode] if mode in ("long-history", "primitive-outcome", "outcome-relation-chain", "mixed-sequence") else []),
                str(public),
                script=script,
                extra_read=paths,
                timeout=1200,
            )
            (public / "solver.log").write_text(result.stdout + result.stderr)
            assert result.returncode == 0, result.stdout + result.stderr
        else:
            assert supervise(root, agent, public) == 0, (
                public / "solver.log"
            ).read_text()
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
        if grounded := decision.get("grounding_read"):
            origin = trace[event["before_ref"]][0]
            assert grounded == {
                "event": origin["event_id"],
                "response_blob": origin["response_blob"],
            }
            source = read(public / "grounding" / (origin["event_id"] + ".json"))
            assert source["response_blob"] == origin["response_blob"]
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
    if mode == "effect-scope-exploration":
        report = read(public / "effect-scope-exploration.json")
        trace = receipts(public)
        measured, prior_effect = trace[report["measured"]]
        selected, outcome = trace[report["selected"]]
        before_measured = trace[measured["before_ref"]][1]["frame"][-1]
        before_selected = trace[selected["before_ref"]][1]["frame"][-1]
        assert measured["action"] == {"id": 6, "x": 9, "y": 11}
        assert selected["action"] == {"id": 6, "x": 39, "y": 11}
        assert before_measured[11][9] == before_selected[11][9] == 4
        assert prior_effect["frame"][-1][11][9] == 9
        assert before_measured[40][44] != before_selected[40][44]
        assert outcome["state"] == "WIN"
        return [report["measured"], report["selected"]]
    if mode in OUTCOME_POLICY_MODES:
        record = read(public / "outcome-policy.json")
        trace = receipts(public)
        event, outcome = trace[record["event"]]
        preparing, prepared = trace[event["before_ref"]]
        assert event["action"] == {"id": 6, "x": 24, "y": 11}
        assert preparing["action"] == {"id": 5}
        assert prepared["frame"][-1][40][44] == 7 and prepared["levels_completed"] == 2
        expected = "WIN" if mode == "outcome-policy" else "GAME_OVER"
        assert outcome["state"] == expected
        assert record["prediction"]["guard_truth"] == "unknown"
        assert record["obligation"]["scope"] == "hypothesis"
        assert record["policy"] == (
            "stopped_at_public_advance" if expected == "WIN" else "withdrawn"
        )
        assert len(record["training_outcomes"]) == 2
        for ref in record["training_outcomes"]:
            training_event, training_after = trace[ref]
            training_prep, training_before = trace[training_event["before_ref"]]
            omitted, unprepared = trace[training_prep["before_ref"]]
            assert training_event["action"] == omitted["action"]
            assert unprepared["frame"][-1][40][44] == 2
            assert training_before["frame"][-1][40][44] == 7
            assert training_before["levels_completed"] == unprepared["levels_completed"]
            assert training_after["levels_completed"] == training_before["levels_completed"] + 1
        digest = record["publication"]
        raw = (public / "publication" / (digest + ".json")).read_bytes()
        assert sha256(raw).hexdigest() == digest
        release = json.loads(raw)
        assert release["calls"] and release["semantic_context"]["consumer"] == "policy-semantics"
        assert record["obligation"]["comparison"] in record["prediction"]["event_reads"]
        return [*record["training_outcomes"], preparing["event_id"], event["event_id"]]
    if mode == "context-reprobe":
        record = read(public / "context-reprobe.json")
        trace = receipts(public)
        first_event, first = trace[record["first"]]
        won_event, won = trace[record["won"]]
        first_before = trace[first_event["before_ref"]][1]
        won_before = trace[won_event["before_ref"]][1]
        assert first["frame"][-1] == first_before["frame"][-1]
        assert first_before["frame"][-1][40][44] == 7
        assert won_before["frame"][-1][40][44] == 8
        assert first_event["action"] == {"id": 6, "x": 9, "y": 11}
        assert won_event["action"] == {"id": 6, "x": 24, "y": 11}
        assert first_event["event_id"] in record["reads"]
        assert record["prior_confirmed_tests"] == 0
        assert won["state"] == "WIN"
        return [first_event["event_id"], won_event["event_id"]]
    if mode == "policy-yield":
        record = read(public / "policy-yield.json")
        trace = receipts(public)
        closed, won = record["closed"], record["won"]
        assert closed == record["yield_source"] and record["baseline"] == {"id": 2}
        assert trace[closed][0]["action"] == {"id": 2}
        assert trace[closed][1]["state"] == "NOT_FINISHED" and trace[closed][1]["levels_completed"] == 0
        assert trace[won][0]["before_ref"] == closed and trace[won][0]["action"] == {"id": 1}
        assert trace[won][1]["state"] == "WIN"
        return [closed, won]
    if mode == "frontier-remote-coordinate":
        record = read(public / "frontier-remote-coordinate.json")
        trace = receipts(public)
        refs = [record[key] for key in ("first", "failed", "reset", "restored", "won")]
        first, failed, reset, restored, won = (trace[ref] for ref in refs)
        assert first[0]["action"] == restored[0]["action"] == {"id": 2}
        assert first[1]["available_actions"] == restored[1]["available_actions"] == [6]
        assert first[1]["frame"] == restored[1]["frame"]
        assert failed[1]["state"] == "GAME_OVER" and failed[0]["action"] == {"id": 6, "x": 9, "y": 11}
        assert reset[0]["action"] == {"id": 0} and reset[1]["available_actions"] == [2]
        assert restored[0]["before_ref"] == refs[2] and won[0]["before_ref"] == refs[3]
        assert won[0]["action"] == {"id": 6, "x": 0, "y": 0} and won[1]["state"] == "WIN"
        prediction = read(public / "predictions" / (restored[0]["command_ref"] + ".json"))
        assert refs[0] in prediction["event_reads"] and refs[1] in prediction["event_reads"]
        return refs
    if mode == "concrete-object-followup":
        record = read(public / "concrete-object-followup.json")
        trace = receipts(public)
        source, selected, won = (record[key] for key in ("source", "selected", "won"))
        original, transfer, win = (trace[ref] for ref in (source, selected, won))
        assert original[0]["action"] == {"id": 6, "x": 9, "y": 11}
        assert original[1]["frame"][-1][35][9] == 7
        assert record["nearby"] == {"id": 6, "x": 24, "y": 11}
        assert transfer[0]["action"] == {"id": 6, "x": 39, "y": 11}
        before = trace[transfer[0]["before_ref"]][1]["frame"][-1]
        assert before[35][24] == 0 and before[35][39] == 2
        assert transfer[1]["frame"][-1][35][39] == 7
        assert transfer[1]["levels_completed"] == 0 and win[1]["state"] == "WIN"
        assert record["task"]["contracts"][0]["scope"] == "unverified"
        assert source in record["task"]["reads"]
        prediction = read(public / "predictions" / (transfer[0]["command_ref"] + ".json"))
        assert prediction["guard_truth"] == "unknown" and source in prediction["event_reads"]
        return [source, selected, won]
    if mode == "advancement-refutation":
        record = read(public / "advancement-refutation.json")
        trace = receipts(public)
        source, failed, won = (record[key] for key in ("source", "failed", "won"))
        first, failure, last = (trace[ref] for ref in (source, failed, won))
        assert first[1]["levels_completed"] == 1 and first[0]["action"]["x"] == 9
        assert failure[1]["levels_completed"] == 1 and failure[0]["action"]["x"] == 39
        assert trace[failure[0]["before_ref"]][1]["frame"][-1] != failure[1]["frame"][-1]
        assert record["transfer"]["event"] == failed and record["transfer"]["scope"]["level"] == 1
        assert last[0]["before_ref"] == failed and last[0]["action"] == {"id": 5}
        assert last[1]["state"] == "WIN" and last[1]["levels_completed"] == 2
        return [source, failed, won]
    if mode == "coordinate-restart":
        record = read(public / "coordinate-restart.json")
        trace = receipts(public)
        first, before = trace[record["failed"]["event"]]
        reset, rebound = trace[record["retry"]]
        last, after = trace[record["next"]["event"]]
        assert first["action"] == {"id": 6, "x": 0, "y": 0} and before["state"] == "GAME_OVER"
        assert reset["action"] == {"id": 0} and reset["before_ref"] == first["event_id"]
        assert rebound["available_actions"] == [6] and rebound["levels_completed"] == 0
        assert last["before_ref"] == reset["event_id"]
        assert last["action"] == {"id": 6, "x": 0, "y": 32} and after["state"] == "WIN"
        return [first["event_id"], reset["event_id"], last["event_id"]]
    if mode == "circuit-role":
        record = read(public / "circuit-role.json")
        trace = receipts(public)
        event, result = trace[record["event"]]
        ref = record["artifact"]
        artifact = read(public / "learning" / "circuits" / (ref + ".json"))
        assert artifact["applicable"] and artifact["calibration"]["accepted"]
        assert artifact["calibration"]["role_improves"]
        assert artifact["dimensions"] == [7, 2, 4] and len(artifact["role_domain"]) == 2
        assert event["action"] == record["chosen"] != record["baseline"]
        assert event["action"]["id"] == record["baseline"]["id"] == 6
        assert record["task"]["obligation"]["circuit"] == ref
        reply = result["action_input"]
        assert reply["id"] == 6 and reply["data"]["game_id"] == result["game_id"]
        assert all(reply["data"][axis] == event["action"][axis] for axis in ("x", "y"))
        prediction = read(public / "predictions" / (event["command_ref"] + ".json"))
        assert ref in prediction["event_reads"]
        trained = set(artifact["model"]["events"])
        checked = artifact["calibration"]["evaluations"]
        assert len({row["key"][2] for row in checked}) == 2
        assert sum(row["model_loss"] for row in checked) < sum(row["marginal_loss"] for row in checked)
        assert trained.isdisjoint(artifact["calibration"]["events"])
        assert all(trace[source][0]["sequence"] < event["sequence"] for source in trained)
        return [ref, event["event_id"]]
    if mode in ("role-outcome", "primitive-outcome", "outcome-relation-chain"):
        record = read(public / f"{mode}.json")
        trace = receipts(public)
        comparison, preparation, original = (record[key]["event"] for key in ("comparison", "preparation", "progress"))
        setup, follow = record["setup"], record["follow"]
        proof = record["progress"]["public_outcome"]["relationship"]
        effect, win = setup["effect"]["event"], follow["win"]["event"]
        assert proof["status"] == "hypothesis"
        assert proof["comparison"] == comparison and proof["preparation"] == preparation
        assert trace[comparison][0]["action"] == trace[original][0]["action"]
        before = [trace[trace[ref][0]["before_ref"]][1]["frame"][-1] for ref in (comparison, preparation)]
        assert before[0] == before[1] and trace[comparison][1]["levels_completed"] == 0
        assert setup["task"]["obligation"]["producer"] == proof["producer"]
        assert setup["task"]["obligation"]["outcome"] == original
        target = 6 if mode == "role-outcome" else 2
        assert setup["baseline"]["id"] == target and trace[effect][0]["action"] == {"id": 5}
        start = trace[trace[effect][0]["before_ref"]][1]
        changed = trace[effect][1]
        available = [2, 5, 7] if mode == "outcome-relation-chain" else sorted([5, target])
        assert start["available_actions"] == changed["available_actions"] == available
        assert start["frame"][-1][40][44] == 2 and changed["frame"][-1][40][44] == 7
        assert setup["effect"]["feedback"]["result"] == "established"
        required = [effect]
        uses = [(effect, setup["task"])]
        if mode == "outcome-relation-chain":
            additional = record["additional"]
            second = additional["effect"]["event"]
            assert [step["event"] for step in proof["chain"]] == [preparation, record["second_source"]["event"]]
            assert trace[second][0]["before_ref"] == effect and trace[second][0]["action"] == {"id": 7}
            assert (changed["frame"][-1][50][48], trace[second][1]["frame"][-1][50][48]) == (3, 8)
            assert trace[second][1]["frame"][-1][40][44] == 7
            assert additional["task"]["obligation"]["confirmed"] == [effect]
            required.append(second)
            uses.append((second, additional["task"]))
        assert follow["task"]["obligation"]["established"] == required[-1]
        assert follow["task"]["obligation"]["confirmed"] == required
        if mode != "role-outcome":
            assert trace[win][0]["action"] == trace[original][0]["action"] == {"id": 2}
            assert before[0] != start["frame"][-1]
        else:
            assert trace[win][0]["action"]["x"] != trace[original][0]["action"]["x"]
        assert trace[win][1]["levels_completed"] == 2 and trace[win][1]["state"] == "WIN"
        for ref, task in [*uses, (win, follow["task"])]:
            command = trace[ref][0]
            prediction = read(public / "predictions" / (command["command_ref"] + ".json"))
            assert set(task["reads"]) <= set(prediction["event_reads"])
            assert all(trace[source][0]["sequence"] < command["sequence"] for source in task["reads"])
        return [comparison, preparation, original, *required, win]
    if mode in ("sequence-experiment", "mixed-sequence"):
        record = read(public / f"{mode}.json")
        trace = receipts(public)
        event, reply = trace[record["event"]]
        prior = [(row, raw) for row, raw in trace.values() if row["sequence"] < event["sequence"]]
        controls = [row["action"]["id"] for row, _ in prior if row["action"]["id"]]
        prefix = record["proposal"]["obligation"]["prefix"]
        observed = [controls[i] for i in range(2, len(controls)) if controls[i-2:i] == prefix]
        assert observed.count(1) == observed.count(2) == 1 and 3 not in observed
        assert prefix == controls[-2:]
        earlier = trace[record["proposal"]["obligation"]["baseline_event"]][0]
        assert earlier["sequence"] < event["sequence"] and earlier["action"] == {"id": 1}
        assert len({tuple(tuple(line) for line in raw["frame"][-1]) for _, raw in prior}) == len(prior)
        assert reply["state"] == "WIN" and event["action"] == {"id": 3}
        service = read(public / "experiments" / ("service-" + event["event_id"] + ".json"))
        assert service["prefix_obligation"] == record["proposal"]["obligation"]
        assert service["cursor"] == record["proposal"]["cursor"] == 1
        if mode == "mixed-sequence":
            assert service["independent"] is True
            assert trace[event["before_ref"]][1]["available_actions"] == [1, 2, 3, 6]
            assert record["intervention"] == {"id": 6, "x": 9, "y": 11}
        return [event["event_id"]]
    if mode in ("history-matrix", "history-receipt", "long-history"):
        record = read(public / "history-matrix.json")
        task = record["task"]
        trace = receipts(public)
        event, response = trace[record["event"]]
        scope = task["obligation"]
        assert scope["scope"] == "observed_history_matrix" and scope["answer"] == "unknown"
        assert scope["current"] != scope["comparison"] and task["action"] == event["action"] == {"id": 2}
        assert response["state"] == "WIN" and trace[scope["source"]][1]["state"] == "NOT_FINISHED"
        assert all(trace[ref][0]["sequence"] < event["sequence"] for ref in task["reads"])
        if mode == "history-receipt":
            source = trace[scope["source"]][0]
            live, live_raw = trace[event["before_ref"]]
            prior, prior_raw = trace[source["before_ref"]]
            assert live["action"] == prior["action"] == {"id": 5}
            assert live_raw["frame"][-1] == prior_raw["frame"][-1]
            assert len(live_raw["frame"]) == len(prior_raw["frame"]) == 2
            assert live_raw["frame"][0] != prior_raw["frame"][0]
            assert {live["event_id"], prior["event_id"]}.issubset(task["reads"])
            assert record["matrix"]["receipts"] and record["matrix"]["width"] == 1
        if mode == "long-history":
            assert not record["matrix"]["receipts"] and record["matrix"]["width"] == 5
            assert [action[0] for action in scope["current"]] == [4, 5, 5, 5, 5]
            assert [action[0] for action in scope["comparison"]] == [1, 5, 5, 5, 5]
            prefixes = []
            for initial in (event, trace[scope["source"]][0]):
                preceding = initial["before_ref"]
                frames = []
                for _ in range(4):
                    prior, raw = trace[preceding]
                    assert prior["action"] == {"id": 5} and preceding in task["reads"]
                    frames.append(raw["frame"])
                    preceding = prior["before_ref"]
                assert preceding in task["reads"]
                prefixes.append(frames)
            assert prefixes[0] == prefixes[1]
        for name, status in (("matrix", "unknown"), ("revised", "observed")):
            row = next(row for row in record[name]["rows"] if row["history"] == scope["current"])
            cell = next((cell for cell in row["cells"] if cell["action"][0] == 2), None)
            if status == "observed":
                assert cell["status"] == status
                assert cell["outcomes"][0][1] == response["state"]
                assert event["event_id"] in cell["reads"]
            else:
                assert cell is None and record[name]["unrecorded_response"] == "unknown"
        prediction = read(public / "predictions" / (event["command_ref"] + ".json"))
        assert prediction["guard_truth"] == "unknown"
        assert set(task["reads"]) <= set(prediction["event_reads"])
        return [record["event"]]
    if mode == "frontier-route":
        route = read(public / "frontier-route.json")
        trace = receipts(public)
        followed, completed = (route[key] for key in ("followed", "completed"))
        first, arrived = trace[followed["event"]]
        last, won = trace[completed["event"]]
        source = trace[followed["task"]["obligation"]["path"][0]][1]
        assert source["frame"] == arrived["frame"]
        assert followed["feedback"] == {"status": "confirmed", "step": 1, "next": 2}
        assert first["action"] == {"id": 2}
        assert last["action"] == {"id": 1} and won["state"] == "WIN"
        assert last["before_ref"] == first["event_id"]
        assert completed["task"]["obligation"]["baseline"] == {"id": 3}
        for record, event in ((followed, first), (completed, last)):
            prediction = read(public / "predictions" / (event["command_ref"] + ".json"))
            assert all(trace[ref][0]["sequence"] < event["sequence"] for ref in record["task"]["reads"])
            assert set(record["task"]["reads"]) <= set(prediction["event_reads"])
        return [first["event_id"], last["event_id"]]
    if mode == "frontier-dispatch":
        record = read(public / "frontier-experiment.json")
        trace = receipts(public)
        event, reply = trace[record["event"]]
        task = record["task"]
        prior = [trace[ref] for ref in task["reads"]]
        assert len(prior) == 2 and all(row["action"] == {"id": 2} for row, _ in prior)
        assert all(row["sequence"] < event["sequence"] for row, _ in prior)
        assert prior[0][1]["frame"] == prior[1][1]["frame"]
        assert task["intent"] == "distinguish_public_frontier"
        assert task["obligation"]["baseline"] == {"id": 2}
        assert event["action"] == task["action"] == {"id": 1}
        assert reply["state"] == "WIN" and reply["levels_completed"] == reply["win_levels"]
        prediction = read(public / "predictions" / (event["command_ref"] + ".json"))
        assert prediction["guard_truth"] == "unknown"
        assert set(task["reads"]) <= set(prediction["event_reads"])
        return [record["event"]]
    if mode == "history-dispatch":
        record = read(public / "history-experiment.json")
        task = record["task"]
        trace = receipts(public)
        event, reply = trace[record["event"]]
        choice = task["obligation"]["history"]
        horizon = choice["scope"]
        artifact = read(public / "learning/histories" / (horizon + ".json"))
        prediction = read(public / "predictions" / (event["command_ref"] + ".json"))
        assert artifact["applicable"] and choice["changed_action"]
        assert task["obligation"]["baseline"] == {"id": 7}
        assert event["action"] == task["action"] == {"id": 2}
        assert reply["action_input"]["id"] == 2
        assert choice["answer"] == prediction["guard_truth"] == "unknown"
        assert (
            horizon in prediction["event_reads"]
            and "2:-1:-1" not in artifact["model"]["edges"][str(choice["state"])]
        )
        assert all(
            trace[source][0]["sequence"] < event["sequence"]
            for source in artifact["model"]["read_events"]
        )
        return [record["event"]]
    rows = list(observed_steps(public))
    if mode == "bridge-partition":
        cut, joined = rows
        assert cut[0]["action"] == {"id": 5}
        source = cut[0]["event_id"]
        topology = read(public / "grounding" / (source + ".json"))["frames"][-1][
            "topology"
        ]
        assert len(topology["splits"]) == 1 and topology["splits"][0]["lost"] == 1
        assert sorted(count for _, count in topology["splits"][0]["after"]) == [4, 4]
        assert joined[3]["intent"] == "probe_partition_binding"
        assert joined[3]["obligation"]["source"] == source
        assert joined[3]["obligation"]["status"] == "unresolved"
        assert joined[1]["frame"][-1][20][joined[0]["action"]["x"]] == 4
        assert joined[2]["state"] == "WIN"
        return [source, joined[0]["event_id"]]
    if mode in ("history-refinement", "history-continuation"):
        failed = next(row for row in rows if row[2]["state"] == "GAME_OVER")
        resolved = next(row for row in rows if "history_refinement" in row[4])
        assert failed[1]["frame"] == resolved[1]["frame"]
        assert failed[0]["action"] == resolved[0]["action"] == {"id": 7}
        refinement = resolved[4]["history_refinement"]
        assert (
            refinement["status"],
            refinement["before_width"],
            refinement["width"],
        ) == ("refined", 1, 2)
        assert refinement["evidence"] == [
            failed[0]["event_id"],
            resolved[0]["event_id"],
        ]
        actions = {row[0]["event_id"]: row[0]["action"]["id"] for row in rows}
        assert [[actions[r] for r in path] for path in refinement["history_reads"]] == [
            [1, 5],
            [4, 5],
        ]
        assert rows[-1][2]["state"] == "WIN"
        if mode == "history-continuation":
            sequences = {event["event_id"]: event["sequence"] for event, *_ in rows}
            history_checks = []
            for event, _, _, task, _ in rows:
                if not task or task["intent"] not in (
                    "test_delayed_effect",
                    "test_history_response",
                ):
                    continue
                history = task["obligation"]["history"]
                if history is None:
                    continue
                scope = history["scope"]
                artifact = read(public / "learning/histories" / (scope + ".json"))
                assert artifact["applicable"] and scope in task["reads"]
                assert set(refinement["evidence"]) <= set(
                    artifact["model"]["read_events"]
                )
                assert all(
                    sequences[source] < event["sequence"]
                    for source in artifact["model"]["read_events"]
                )
                assert history["answer"] == "unknown"
                key = ":".join(
                    str(event["action"].get(k, -1)) for k in ("id", "x", "y")
                )
                assert key not in artifact["model"]["edges"][str(history["state"])]
                history_checks.append(event["event_id"])
            artifacts = [
                read(path) for path in (public / "learning/histories").glob("*.json")
            ]
            assert any(item["applicable"] for item in artifacts)
            return refinement["evidence"] + history_checks
        return refinement["evidence"]
    if mode == "advancement-transfer":
        first, second = rows
        assert first[2]["levels_completed"] == 1
        assert second[3]["intent"] == "probe_observed_advancement"
        assert second[3]["obligation"]["source"] == first[0]["event_id"]
        assert second[3]["obligation"]["scope"] == "new_instance"
        assert second[0]["action"]["x"] != first[0]["action"]["x"]
        assert second[4]["feedback"]["result"] == "established"
        assert second[2]["state"] == "WIN"
        return [row[0]["event_id"] for row in rows]
    if mode == "outcome-preparation":
        initial, advanced, prepared, won = rows
        assert initial[0]["action"] == prepared[0]["action"] == {"id": 5}
        assert initial[1]["frame"] == initial[2]["frame"]
        source = advanced[4]["public_outcome"]
        assert source["result"] == "advancement"
        assert source["preparation"]["event"] == initial[0]["event_id"]
        assert prepared[3]["intent"] == "prepare_public_outcome"
        assert prepared[3]["obligation"]["outcome"] == advanced[0]["event_id"]
        assert prepared[3]["obligation"]["scope"] == "new_instance"
        assert prepared[4]["feedback"]["result"] == "established"
        assert advanced[0]["action"]["x"] != won[0]["action"]["x"]
        assert won[2]["state"] == "WIN"
        result = won[4]["public_outcome"]
        assert result["result"] == "win" and not result["local_effects_complete"]
        assert result["preparation"]["event"] == prepared[0]["event_id"]
        return [row[0]["event_id"] for row in rows]
    if mode == "outcome-chain":
        first, enabled, advanced, rebound, continued, won = rows
        assert [row[0]["action"]["id"] for row in rows] == [5, 2, 6, 5, 2, 6]
        assert first[2]["available_actions"] == rebound[2]["available_actions"] == [2]
        assert enabled[2]["available_actions"] == continued[2]["available_actions"] == [6]
        assert all(
            all(frame == row[1]["frame"][-1] for frame in row[2]["frame"])
            for row in (first, enabled, rebound, continued)
        )
        expected = [(first[0]["event_id"], 2), (enabled[0]["event_id"], 6)]
        requirements = advanced[4]["public_outcome"]["requirements"]
        assert [(row["event"], row["action"]) for row in requirements] == expected
        for step, row in enumerate((rebound, continued), 1):
            assert row[3]["intent"] == "prepare_public_outcome"
            obligation = row[3]["obligation"]
            assert obligation["outcome"] == advanced[0]["event_id"]
            assert obligation["step"] == step
            assert [(part["event"], part["action"]) for part in obligation["chain"]] == expected
            assert row[4]["feedback"]["result"] == "established"
        assert advanced[0]["action"]["x"] != won[0]["action"]["x"]
        assert won[2]["levels_completed"] == 2 and won[2]["state"] == "WIN"
        return [row[0]["event_id"] for row in rows]
    if mode == "restart-choices":
        assert [row[2]["state"] for row in rows] == ["GAME_OVER", "GAME_OVER", "WIN"]
        assert len({row[0]["action"]["x"] for row in rows}) == 3
        assert all(row[3]["intent"] == "revise_failed_trace" for row in rows[1:])
        resets = read(public / "learning/deferred-tail.json")
        assert resets["public_state"] == "WIN"
        return [row[0]["event_id"] for row in rows]
    if mode == "progress-restart":
        original = next(row for row in rows if row[2]["levels_completed"] == 1)
        failure = next(row for row in rows if row[2]["state"] == "GAME_OVER")
        recover = next(
            row
            for row in rows
            if (row[3] or {}).get("intent") == "recover_confirmed_progress"
        )
        assert recover[1]["levels_completed"] == 0
        assert recover[2]["levels_completed"] == 1
        assert recover[0]["action"] == original[0]["action"]
        assert recover[3]["obligation"]["source"] == original[0]["event_id"]
        assert recover[4]["feedback"]["result"] == "established"
        revised = rows[rows.index(recover) + 1]
        assert revised[3]["intent"] == "revise_failed_trace"
        assert revised[0]["action"] != failure[0]["action"]
        assert revised[2]["state"] == "WIN"
        return [row[0]["event_id"] for row in (original, failure, recover, revised)]
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
    run = run.resolve()
    (run / "grade").mkdir(parents=True, exist_ok=True)
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

    modes = (
        "delayed",
        "remote",
        "directions",
        "restart",
        "progress-restart",
        "restart-choices",
        "advancement-transfer",
        "advancement-refutation",
        "concrete-object-followup",
        "outcome-preparation",
        "outcome-chain",
        "role-outcome",
        "primitive-outcome",
        "outcome-relation-chain",
        *OUTCOME_POLICY_MODES,
        "history-refinement",
        "history-dispatch",
        "circuit-role",
        "coordinate-restart",
        "bridge-partition",
        "context-reprobe",
        "effect-scope-exploration",
        "frontier-dispatch",
        "policy-yield",
        "frontier-route",
        "frontier-remote-coordinate",
        "history-matrix",
        "history-receipt",
        "long-history",
        "sequence-experiment",
        "mixed-sequence",
    )
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
            budget="unlimited"
            if mode
            in (
                *OUTCOME_POLICY_MODES,
                "progress-restart",
                "restart-choices",
                "history-refinement",
                "history-continuation",
                "outcome-preparation",
                "outcome-chain",
                "role-outcome",
                "frontier-dispatch",
                "frontier-route",
                "history-matrix",
                "history-receipt",
                "long-history",
                "sequence-experiment",
                "circuit-role",
                "coordinate-restart",
            )
            else 9,
            compute=bool(extra),
        )
        if extra:
            verify(mode, public)
        if extra and mode in ("history-refinement", "history-continuation"):
            backends = read(public / "learning/backends.json")
            assert backends["circuit_python"]["aalpy"]["version"] == "2.0.0"
        elif extra:
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
