"""Verify synthetic environment behavior against hand checks and a separate oracle."""

from hashlib import sha256

import requests
from arcengine import ActionInput, GameAction

from . import reference
from .game import ShapeGame


def frame_hash(frame):
    return sha256(bytes(x for row in frame for x in row)).hexdigest()


def engine_transition(scene, state, action):
    game = ShapeGame(scene)
    game.perform_action(ActionInput(id=GameAction.RESET), raw=True)
    game.restore(state)
    if action == 0:
        value = game.perform_action(ActionInput(id=GameAction.RESET), raw=True)
    else:
        number, coords = concrete_request(action)
        value = game.perform_action(
            ActionInput(id=GameAction.from_id(number), data=coords), raw=True
        )
    return (
        game.snapshot(),
        [frame.tolist() for frame in value.frame],
        value.available_actions,
    )


def finite_engine_check(scene):
    states, edges = 0, 0
    for state in reference.reachable(scene):
        states += 1
        for action in reference.concrete_actions(scene, state):
            outcome = reference.transition(scene, state, action)
            actual, frames, actions = engine_transition(scene, state, action)
            if (
                outcome != actual
                or frames != reference.render_response(scene, state, action, outcome)
                or actions != list(reference.available_actions(scene, outcome))
            ):
                raise AssertionError(
                    (scene.case, scene.variant, state, action, outcome, actual)
                )
            edges += 1
    return {"states": states, "transitions": edges, "domain": list(scene.actions)}


def logical_sample(scene, frame, x, y):
    left, top, width, height, scale, x0, y0 = reference.screen_geometry(scene)
    assert left <= x < left + width and top <= y < top + height
    return frame[y0 + (y - top) * scale][x0 + (x - left) * scale]


def concrete_request(action):
    if isinstance(action, tuple):
        number, x, y = action
        return number, {"x": x, "y": y}
    return action, {}


def hand_checks(by_variant, public_frames=None):
    def at(name, index):
        if public_frames is not None:
            return public_frames[name][index]
        scene = by_variant[name]
        state = scene.start_state
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
    assert (
        reference.transition(swap, swap.start_state, 1).positions
        == swap.start[::-1]
        != swap.start
    )
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
    panel_open = by_variant["panel-open"]
    x, y = panel_open.start[0]
    local = [(u, v) for v in range(y - 3, y + 4) for u in range(x - 3, x + 4)]
    assert all(
        logical_sample(panel_open, at("panel-open", 0), u, v)
        == logical_sample(panel_open, at("panel-closed", 0), u, v)
        for u, v in local
    )
    assert at("panel-open", 0) != at("panel-open", 1)
    assert at("panel-closed", 0) == at("panel-closed", 1)
    assert at("panel-toggle", 0) == at("panel-toggle", 1)
    assert at("panel-toggle", 2) == at("panel-open", 0)
    assert at("panel-toggle", 3) == at("panel-open", 1)
    assert at("panel-cropped-open", 0) == at("panel-cropped-closed", 0)
    assert at("panel-cropped-open", 1) != at("panel-cropped-closed", 1)
    assert at("panel-unrelated", 0) != at("panel-open", 0)
    assert at("panel-unrelated", 0) != at("panel-unrelated", 1)
    assert at("panel-position-heldout", 0) != at("panel-position-heldout", 1)

    push = by_variant["push-open"]
    actor, obstacle = push.start
    pushed = reference.transition(push, push.start_state, 1)
    assert pushed.positions == (
        (actor[0] + 1, actor[1]),
        (obstacle[0] + 1, obstacle[1]),
    )
    assert at("push-open", 0) == at("push-immovable", 0)
    assert (
        logical_sample(push, at("push-open", 1), obstacle[0] + 1, obstacle[1])
        == push.bodies[1][0][2]
    )
    assert (
        logical_sample(push, at("push-open", 1), obstacle[0], obstacle[1])
        == push.bodies[0][0][2]
    )
    for name in ("push-blocked", "push-immovable"):
        assert at(name, 0) == at(name, 1)

    resource = by_variant["resource-one"]
    x, y = resource.resource.panel
    assert (
        logical_sample(resource, at("resource-one", 0), x, y) == resource.resource.color
    )
    assert logical_sample(resource, at("resource-one", 1), x, y) == resource.background
    assert at("resource-zero", 0) == at("resource-zero", 1)
    assert (
        logical_sample(resource, at("resource-two", 1), x, y) == resource.resource.color
    )
    assert (
        logical_sample(resource, at("resource-two", 1), x + 2, y) == resource.background
    )
    before = at("resource-no-movement", 0)
    after = at("resource-no-movement", 1)
    assert before != after and after == at("resource-zero", 0) == at(
        "resource-no-movement", 2
    )
    entered = reference.transition(resource, resource.start_state, 1)
    assert entered.resource == 0 and entered.positions != resource.start
    assert reference.transition(resource, entered, 1).resource == 0

    clicks = []
    for name in (
        "click-interior",
        "click-edge-outside",
        "click-letterbox",
        "click-panel",
        "click-between",
        "click-viewport21",
        "click-overlap-a",
        "click-overlap-b",
    ):
        scene = by_variant[name]
        action = scene.prefix[0]
        before, selected, moved = (at(name, i) for i in range(3))
        succeeds = name in ("click-interior", "click-viewport21")
        obscured = name.startswith("click-overlap-")
        assert (before != selected) == succeeds
        if obscured:
            assert before == moved
        else:
            role = 1 if succeeds else 0
            x0, y0 = scene.start[role]
            assert logical_sample(scene, moved, x0 + 2, y0) == scene.bodies[role][0][2]
        clicks.append(
            {
                "variant": name,
                "coordinate": list(action[1:]),
                "selected_changed": succeeds,
            }
        )
    assert at("click-overlap-a", 0) == at("click-overlap-b", 0)

    boundary = boundary_hand_checks(by_variant, at)
    return {
        "M01": move_groups,
        "M02": {
            "first_new_free_cell": [anchor + 2, 6],
            "edge_conflict": [anchor + 2, 7],
            "long_sweep_conflict": list(by_variant["long-swept"].blocked[0]),
        },
        "M05": {
            "local_equal_cells": len(local),
            "panel": list(panel_open.switch.panel),
            "toggle_after_block": [1, 5, 1],
            "cropped_before_equal": True,
        },
        "M04": {
            "joint": pushed.positions,
            "blocked_space": [obstacle[0] + 1, obstacle[1] + 1],
        },
        "M06": {
            "forward_charge": [1, 0],
            "empty_charge": [0, 0],
            "without_movement": [1, 0],
        },
        "M08": clicks,
        "M13": {
            "full_components": [sorted(s) for s in full],
            "crop_origin": [0, 7],
            "cropped_components": [sorted(s) for s in cropped],
            "diagonal_counts_4_8": [2, 1],
            "contact_components": counts,
        },
        **boundary,
    }


def boundary_hand_checks(scenes, at):
    narrow, wide = scenes["walk-narrow-bridge"], scenes["walk-wide-bridge"]
    assert at(narrow.variant, 0) == at(narrow.variant, 1)
    assert at(wide.variant, 0) != at(wide.variant, 1)
    assert all(s.positions[0][0] < 16 for s in reference.reachable(wide))
    assert (
        at("latch-untriggered", 0)
        == at("latch-triggered", 0)
        == at("latch-triggered", 1)
    )
    assert at("latch-untriggered", 1) == at("latch-untriggered", 0)
    assert at("latch-triggered", 2) != at("latch-triggered", 1)
    assert at("latch-triggered", 2) == at("latch-triggered", 3)
    pushed = scenes["undo-push-and-charge"]
    after = reference.transition(pushed, pushed.start_state, 1)
    undo = reference.transition(pushed, after, 7)
    assert after.positions != pushed.start and undo.positions == pushed.start
    assert (pushed.start_state.resource, after.resource, undo.resource) == (1, 0, 0)
    assert at("undo-empty", 0) != at("undo-empty", 1)
    assert (
        at("stationary-domain", 0)
        == at("stationary-domain", 1)
        == at("stationary-domain", 2)
    )
    assert at("stationary-charge", 0) != at("stationary-charge", 1)
    assert at("stationary-identical", 0) == at("stationary-identical", 1)
    assert at("flash-positive", 0) == at("flash-positive", 1) == at("flash-negative", 1)
    assert at("flash-positive", 2) != at("flash-negative", 2)
    assert at("tracking-landmarks", 0) != at("tracking-landmarks", 1)
    assert at("tracking-without-landmarks", 0) == at("tracking-without-landmarks", 1)
    peer = scenes["autonomous-peer"]
    advanced = reference.transition(peer, peer.start_state, 5)
    assert (
        peer.start[0] == advanced.positions[0]
        and peer.start[1] != advanced.positions[1]
    )
    assert at("indistinguishable-gate", 0) == at("indistinguishable-decoy", 0)
    assert at("indistinguishable-gate", 1) == at("indistinguishable-decoy", 1)
    assert at("indistinguishable-gate", 2) != at("indistinguishable-decoy", 2)
    return {
        "M03": {"narrow_entry": False, "wide_entry": True, "walk_to_island": False},
        "M07": {"equal_last_frame_before_motion": True, "latch_consumed": True},
        "M09": {"resources": [1, 0, 0], "restored_positions": undo.positions},
        "M10": {"identical_frames_after_domain_change": True, "remaining_actions": [2]},
        "M11": {"same_endpoint": True, "different_next_motion": True},
        "M12": {
            "above_tracking_threshold": True,
            "autonomous_without_actor_motion": True,
        },
        "M14": {"same_prefix_actions": [0, 1], "first_distinguishing_action": 5},
    }


def boundary_trace_checks(traces):
    def records(variant):
        return [
            entry["response"] for entry in traces[variant] if "/cmd/" in entry["path"]
        ]

    latch = records("latch-triggered")
    assert len(latch[1]["frame"]) == 3 and latch[1]["frame"][-1] == latch[0]["frame"][0]
    positive, negative = records("flash-positive"), records("flash-negative")
    left, right = positive[1]["frame"], negative[1]["frame"]
    assert len(left) == len(right) == 3
    assert left[0] == right[0] and left[0] != left[-1]
    assert left[-1] == right[-1] and left[1] != right[1]
    domain = records("stationary-domain")
    assert domain[0]["available_actions"] == [1, 2] and domain[1][
        "available_actions"
    ] == [2]
    gate, decoy = records("indistinguishable-gate"), records("indistinguishable-decoy")
    public_fields = (
        "frame",
        "state",
        "levels_completed",
        "win_levels",
        "available_actions",
    )
    for a, b in zip(gate[:2], decoy[:2], strict=True):
        assert all(a[key] == b[key] for key in public_fields)
        assert a["action_input"]["id"] == b["action_input"]["id"]
    assert gate[2]["frame"] != decoy[2]["frame"]


def http_trace(url, scene):
    state = scene.start_state
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
            number, coordinates = concrete_request(action)
            body = {"game_id": scene.public_id, **coordinates}
            if guid is None:
                body["card_id"] = card
            else:
                body["guid"] = guid
            response = call(
                "/api/cmd/" + ("RESET" if number == 0 else f"ACTION{number}"), body
            )
            expected_state = reference.transition(scene, state, action)
            expected_frames = reference.render_response(
                scene, state, action, expected_state
            )
            assert response["game_id"] == scene.public_id
            assert len(response["guid"]) > 0 and (
                guid is None or guid == response["guid"]
            )
            assert response["state"] == "NOT_FINISHED"
            assert response["levels_completed"] == 0 and response["win_levels"] == 1
            assert response["available_actions"] == list(
                reference.available_actions(scene, expected_state)
            )
            assert response["action_input"]["id"] == number
            if number == 6:
                echo = response["action_input"]["data"]
                assert all(
                    type(echo[key]) is int and echo[key] == value
                    for key, value in coordinates.items()
                )
            assert response["frame"] == expected_frames, (
                scene.case,
                scene.variant,
                state,
                action,
            )
            state = expected_state
            guid = response["guid"]
            frames.append(response["frame"][-1])
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
