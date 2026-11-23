"""Verify synthetic environment behavior against hand checks and a separate oracle."""

from dataclasses import replace
from hashlib import sha256

import requests
from arcengine import ActionInput, GameAction

from . import reference
from .game import ShapeGame


def frame_hash(frame):
    return sha256(bytes(x for row in frame for x in row)).hexdigest()


def engine_transition(scene, state, action):
    game = ShapeGame(replace(scene, start=state))
    game.perform_action(ActionInput(id=GameAction.RESET), raw=True)
    if action == 0:
        value = game.perform_action(ActionInput(id=GameAction.RESET), raw=True)
    else:
        value = game.perform_action(
            ActionInput(id=GameAction.from_id(action)), raw=True
        )
    return tuple(game.positions), [frame.tolist() for frame in value.frame]


def finite_engine_check(scene):
    states, edges = 0, 0
    for state in reference.reachable(scene):
        states += 1
        for action in scene.actions:
            outcome = reference.transition(scene, state, action)
            actual, frames = engine_transition(scene, state, action)
            if outcome != actual or frames != [reference.render(scene, outcome)]:
                raise AssertionError(
                    (scene.case, scene.variant, state, action, outcome, actual)
                )
            edges += 1
    return {"states": states, "transitions": edges, "domain": list(scene.actions)}


def logical_sample(scene, frame, x, y):
    left, top, width, height, scale, x0, y0 = reference.screen_geometry(scene)
    assert left <= x < left + width and top <= y < top + height
    return frame[y0 + (y - top) * scale][x0 + (x - left) * scale]


def hand_checks(by_variant, public_frames=None):
    def at(name, index):
        if public_frames is not None:
            return public_frames[name][index]
        scene = by_variant[name]
        state = scene.start
        for action in scene.prefix[:index]:
            state = reference.transition(scene, state, action)
        return reference.render(scene, state)

    wide = by_variant["open-wide"]
    anchor = wide.start[0][0]
    before, after = at("open-wide", 0), at("open-wide", 1)
    color = wide.bodies[0][0][2]
    move_groups = {
        "exit": [(anchor, 6), (anchor, 7)],
        "overlap": [(anchor + 1, 6), (anchor + 2, 6), (anchor + 1, 7), (anchor + 2, 7)],
        "enter": [(anchor + 3, 6), (anchor + 3, 7)],
    }
    expected_colors = {
        "exit": (color, wide.background),
        "overlap": (color, color),
        "enter": (wide.background, color),
    }
    for group, points in move_groups.items():
        for x, y in points:
            assert (
                logical_sample(wide, before, x, y),
                logical_sample(wide, after, x, y),
            ) == expected_colors[group]
    assert at("edge-blocker", 0) == at("edge-blocker", 1)
    assert (
        at("equal-appearance-swap", 0)
        == at("equal-appearance-swap", 1)
        == at("equal-appearance-idle", 1)
    )
    swap = by_variant["equal-appearance-swap"]
    assert reference.transition(swap, swap.start, 1) == swap.start[::-1] != swap.start
    assert at("open-square", 0) != at("open-square", 1)
    distractor = by_variant["same-color-distractor"]
    assert all(
        logical_sample(distractor, at("same-color-distractor", i), 10, 8) == color
        for i in (0, 1)
    )

    narrow = by_variant["narrow-corridor"]
    assert logical_sample(narrow, at("narrow-corridor", 0), anchor + 1, 6) == color
    # The requested target anchor is initially overlapped by the moving body itself.
    # The additional target edge cell is either free or blocked, with the same source anchor.
    assert (
        logical_sample(narrow, at("narrow-corridor", 0), anchor + 2, 6)
        == narrow.background
    )
    assert (
        logical_sample(narrow, at("narrow-corridor", 0), anchor + 2, 7)
        != narrow.background
    )
    assert at("wide-corridor", 0) != at("wide-corridor", 1)
    for v in ("narrow-corridor", "floor-hole", "active-boundary", "long-swept"):
        assert at(v, 0) == at(v, 1), v
    for v in ("l-notch", "long-endpoint"):
        assert at(v, 0) != at(v, 1), v
    assert at("long-endpoint", 0) == at("long-swept", 0)
    assert at("offscreen-open", 0) == at("offscreen-blocked", 0)
    assert at("offscreen-open", 1) != at("offscreen-blocked", 1)

    bridge = by_variant["bridge-and-diagonal"]
    bridge_color = bridge.static[0][2]
    diagonal_color = bridge.static[-1][2]
    frame = at("bridge-and-diagonal", 0)
    bridge_points = {
        (x, y)
        for x in range(1, 10)
        for y in (6, 7)
        if logical_sample(bridge, frame, x, y) == bridge_color
    }
    full = reference.components(bridge_points)
    cropped = reference.components({(x, 0) for x, y in bridge_points if y == 7})
    diagonal = {
        (x, y)
        for x in range(13, 17)
        for y in range(11, 15)
        if logical_sample(bridge, frame, x, y) == diagonal_color
    }
    assert len(full) == 1 and len(full[0]) == 9
    assert sorted(map(len, cropped)) == [2, 2]
    assert len(reference.components(diagonal)) == 2
    assert len(reference.components(diagonal, eight=True)) == 1
    rigid = by_variant["multicolor-rigid"]
    for dx, dy, value in rigid.bodies[0]:
        x, y = rigid.start[0]
        assert logical_sample(rigid, at("multicolor-rigid", 0), x + dx, y + dy) == value
        assert (
            logical_sample(rigid, at("multicolor-rigid", 1), x + dx + 1, y + dy)
            == value
        )
    touch = by_variant["touch-and-separate"]
    counts = [
        len(
            reference.components(
                {
                    (x, y)
                    for x in range(2, 11)
                    for y in (6, 7)
                    if logical_sample(touch, at("touch-and-separate", i), x, y) == color
                }
            )
        )
        for i in range(3)
    ]
    assert counts == [2, 1, 2] and at("touch-and-separate", 0) == at(
        "touch-and-separate", 2
    )
    return {
        "M01": move_groups,
        "M02": {
            "first_new_free_cell": [anchor + 2, 6],
            "edge_conflict": [anchor + 2, 7],
            "long_sweep_conflict": list(by_variant["long-swept"].blocked[0]),
        },
        "M13": {
            "full_components": [sorted(s) for s in full],
            "crop_origin": [0, 7],
            "cropped_components": [sorted(s) for s in cropped],
            "diagonal_counts_4_8": [2, 1],
            "contact_components": counts,
        },
    }


def http_trace(url, scene):
    state = scene.start
    frames = []
    trace = []
    with requests.Session() as http:
        http.trust_env = False

        def call(route, body):
            response = http.post(url + route, json=body, timeout=5)
            response.raise_for_status()
            trace.append(
                {
                    "path": route,
                    "request": body,
                    "status": response.status_code,
                    "body_sha256": sha256(response.content).hexdigest(),
                    "response": response.json(),
                }
            )
            return trace[-1]["response"]

        card = call("/api/scorecard/open", {})["card_id"]
        guid = None
        for action in (0, *scene.prefix):
            body = {"game_id": scene.public_id}
            if guid is None:
                body["card_id"] = card
            else:
                body["guid"] = guid
            response = call(
                "/api/cmd/" + ("RESET" if action == 0 else f"ACTION{action}"), body
            )
            expected_state = reference.transition(scene, state, action)
            expected_frame = reference.render(scene, expected_state)
            assert response["game_id"] == scene.public_id
            assert len(response["guid"]) > 0 and (
                guid is None or guid == response["guid"]
            )
            assert response["state"] == "NOT_FINISHED"
            assert response["levels_completed"] == 0 and response["win_levels"] == 1
            assert response["available_actions"] == list(scene.actions)
            assert response["action_input"]["id"] == action
            assert response["frame"] == [expected_frame], (
                scene.case,
                scene.variant,
                state,
                action,
            )
            state = expected_state
            guid = response["guid"]
            frames.append(response["frame"][0])
        call("/api/scorecard/close", {"card_id": card})
    return frames, trace


def compare_repeated_traces(first, second):
    def behavior(trace):
        keys = (
            "game_id",
            "state",
            "levels_completed",
            "win_levels",
            "available_actions",
            "action_input",
            "frame",
        )
        return [
            (row["path"], {key: row["response"][key] for key in keys})
            for row in trace
            if row["path"].startswith("/api/cmd/")
        ]

    assert behavior(first) == behavior(second)
