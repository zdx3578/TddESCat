"""Finite reference transitions and public-frame oracle independent of ARCEngine."""

from collections import deque
from dataclasses import replace

from .scenario import Command, Scene, State


def transition(scene: Scene, state: State, action: Command) -> State:
    if action == 0:
        return scene.start_state
    mode = scene.dynamics
    if isinstance(action, int) and action not in available_actions(scene, state):
        raise ValueError("Action outside finite domain")
    if action == 7 and mode.startswith("undo-"):
        positions = state.positions
        if state.previous_positions is not None:
            positions = (
                (state.previous_positions[0], *positions[1:])
                if mode == "undo-first"
                else state.previous_positions
            )
        return replace(
            state,
            positions=positions,
            flagged=mode != "undo-with-token"
            or (state.previous_positions is not None and state.resource == 0),
            previous_positions=None,
        )
    if action == 5 and mode in ("latched", "flash", "flash-closed"):
        return replace(state, flagged=mode != "flash-closed")
    if action == 5 and mode == "decoy-switch":
        return replace(state, flagged=not state.flagged)
    if action == 5 and mode == "autonomous":
        return advance_peer(scene, state)
    result = rigid_transition(scene, state, action)
    if mode == "autonomous":
        return advance_peer(scene, result)
    if mode == "charge-still" and action == 1:
        return replace(result, resource=max(0, result.resource - 1))
    if mode == "action-domain" and action == 1:
        return replace(result, flagged=True)
    if result.positions != state.positions:
        if mode.startswith("undo-"):
            return replace(result, previous_positions=state.positions)
        if mode in ("latched", "flash", "flash-closed"):
            return replace(result, flagged=False)
    return result


def advance_peer(scene, state):
    first, (x, y) = state.positions
    return replace(state, positions=(first, (min(x + 1, scene.logical_size[0] - 1), y)))


def rigid_transition(scene, state, action):
    if action == 5 and scene.switch:
        return replace(state, switch_on=not state.switch_on)
    if action == 5 and scene.resource:
        return replace(state, resource=max(state.resource - 1, 0))
    if (
        isinstance(action, tuple)
        and action[0] == 6
        and scene.selection_color is not None
    ):
        _, sx, sy = action
        left, top, width, height, zoom, px, py = screen_geometry(scene, state)
        if not (px <= sx < px + width * zoom and py <= sy < py + height * zoom):
            return state
        target = (left + (sx - px) // zoom, top + (sy - py) // zoom)
        candidates = [
            index
            for index, (shape, (x, y)) in enumerate(
                zip(scene.bodies, state.positions, strict=True)
            )
            if any((x + u, y + v) == target for u, v, _ in shape)
        ]
        return replace(state, selected=candidates[0]) if len(candidates) == 1 else state
    positions = state.positions
    mapping = [(dx, dy) for number, dx, dy in scene.moves if number == action]
    if len(mapping) != 1:
        raise ValueError("Action outside finite domain")
    if not positions:
        return state
    if scene.path_policy == "swap":
        return replace(state, positions=positions[::-1])

    left, top, right, bottom = scene.active
    floor = {(x, y) for y in range(top, bottom) for x in range(left, right)}
    floor.difference_update(scene.blocked, scene.holes)
    allowed = (
        state.flagged
        if scene.dynamics in ("latched", "flash", "flash-closed")
        else state.switch_on
    )
    if scene.switch and not allowed:
        floor.difference_update(scene.switch.gate_cells)
    footprints = [
        {(x + u, y + v) for u, v, _ in shape}
        for shape, (x, y) in zip(scene.bodies, positions, strict=True)
    ]
    moving = state.selected
    if scene.contact_rule is not None and scene.contact_rule[0] == action:
        visible = {
            (x, y) for x, y, color in scene.static if color == scene.contact_rule[1]
        }
        subject = footprints[moving]
        fringe = {
            (x + dx, y + dy)
            for x, y in subject
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))
        }
        if visible.isdisjoint(fringe):
            return state
    occupied = set().union(
        *(cells for i, cells in enumerate(footprints) if i != moving)
    )

    delta_x, delta_y = mapping[0]
    anchor_x, anchor_y = positions[moving]
    end = (anchor_x + delta_x, anchor_y + delta_y)
    path = [end]
    if scene.path_policy == "swept":
        if delta_x and delta_y:
            raise ValueError("Finite fixtures require axial motion")
        if delta_x:
            sign = 1 if delta_x > 0 else -1
            path = [(x, anchor_y) for x in range(anchor_x + sign, end[0] + sign, sign)]
        elif delta_y:
            sign = 1 if delta_y > 0 else -1
            path = [(anchor_x, y) for y in range(anchor_y + sign, end[1] + sign, sign)]
    for x, y in path[:-1]:
        if any(
            (x + u, y + v) not in floor - occupied for u, v, _ in scene.bodies[moving]
        ):
            return state
    destination = {(u + delta_x, v + delta_y) for u, v in footprints[moving]}
    if not destination <= floor:
        return state
    use_resource = scene.resource is not None and not (
        destination.intersection(scene.resource.gate_cells) <= footprints[moving]
    )
    if use_resource and state.resource < 1:
        return state
    next_pos = list(positions)
    blockers = [
        index
        for index, cells in enumerate(footprints)
        if index != moving and cells & destination
    ]
    if blockers:
        if len(blockers) > 1 or not scene.pushable:
            return state
        index = blockers[0]
        shifted = {(x + delta_x, y + delta_y) for x, y in footprints[index]}
        free = floor - (occupied - footprints[index]) - destination
        if not shifted <= free:
            return state
        x, y = positions[index]
        next_pos[index] = (x + delta_x, y + delta_y)
    next_pos[moving] = end
    return replace(
        state, positions=tuple(next_pos), resource=state.resource - int(use_resource)
    )


def logical_colors(scene, state, *, signal=False):
    colors = {(x, y): color for x, y, color in scene.static}
    if scene.switch:
        left, top = scene.switch.panel
        color = scene.switch.on_color if state.switch_on else scene.switch.off_color
        for x in range(left, left + 2):
            for y in range(top, top + 2):
                colors[x, y] = color
    if scene.resource:
        x, y = scene.resource.panel
        colors.update(
            {
                (x + scene.resource.display_spacing * i, y): scene.resource.color
                for i in range(state.resource)
            }
        )
    if scene.selection_color is not None:
        x, y = state.positions[state.selected]
        rectangle = {(u, v) for u in range(x - 1, x + 3) for v in range(y - 1, y + 3)}
        inside = {(x, y), (x + 1, y), (x, y + 1), (x + 1, y + 1)}
        colors.update(dict.fromkeys(rectangle - inside, scene.selection_color))
    if scene.signal and (
        signal
        or (
            state.flagged
            and (scene.dynamics.startswith("undo-") or scene.dynamics == "decoy-switch")
        )
    ):
        x, y, color = scene.signal
        colors[(x, y)] = color
    for (x, y), body in zip(state.positions, scene.bodies, strict=True):
        colors.update({(x + u, y + v): color for u, v, color in body})
    return colors


def screen_geometry(scene, state=None):
    left, top, width, height = scene.viewport
    origin = scene.tracking_origin
    if origin is None and scene.dynamics == "tracking":
        origin = 18
    if state is not None and origin is not None:
        left = min(
            max(0, state.positions[0][0] - origin), scene.logical_size[0] - width
        )
    scale = 64 // max(width, height)
    return (
        left,
        top,
        width,
        height,
        scale,
        (64 - width * scale) // 2,
        (64 - height * scale) // 2,
    )


def render(scene: Scene, state: State, *, signal=False):
    colors = logical_colors(scene, state, signal=signal)
    left, top, width, height, scale, start_x, start_y = screen_geometry(scene, state)
    screen = [[scene.letterbox] * 64 for _ in range(64)]
    for y in range(height):
        for x in range(width):
            color = colors.get((left + x, top + y), scene.background)
            dest_x, dest_y = start_x + x * scale, start_y + y * scale
            for row in range(dest_y, dest_y + scale):
                screen[row][dest_x : dest_x + scale] = [color] * scale
    return screen


def render_response(scene, state, action, outcome):
    if action == 5 and scene.dynamics in ("latched", "flash", "flash-closed"):
        first = state
        if scene.dynamics.startswith("flash"):
            x, y = state.positions[0]
            first = replace(state, positions=((x + 1, y), *state.positions[1:]))
        return [
            render(scene, first),
            render(scene, state, signal=True),
            render(scene, outcome),
        ]
    return [render(scene, outcome)]


def available_actions(scene, state):
    return tuple(
        action
        for action in scene.actions
        if not (scene.dynamics == "action-domain" and state.flagged and action == 1)
    )


def goal_reached(scene, state):
    if scene.goal is None:
        return False
    role = scene.goal_role
    if scene.goal_with_signal and (not state.flagged or state.selected != role):
        return False
    x, y = state.positions[role]
    target_x, target_y = scene.goal
    return any(
        0 < abs(x + dx - target_x) + abs(y + dy - target_y) <= scene.goal_distance
        for dx, dy, _ in scene.bodies[role]
    )


def reachable(scene, start=None):
    initial = scene.start_state if start is None else start
    frontier = deque([initial])
    seen = {initial}
    while frontier:
        state = frontier.popleft()
        yield state
        if goal_reached(scene, state):
            continue
        for action in concrete_actions(scene, state):
            candidate = transition(scene, state, action)
            if candidate not in seen:
                seen.add(candidate)
                frontier.append(candidate)


def concrete_actions(scene, state):
    actions = [action for action in available_actions(scene, state) if action != 6]
    if scene.selection_color is None:
        return actions
    left, top, _, _, zoom, px, py = screen_geometry(scene, state)
    points = {(0, 0), (32, 32)}
    for x, y in state.positions:
        sx, sy = px + (x - left) * zoom, py + (y - top) * zoom
        points.update(((sx, sy), (sx - 1, sy), (sx + zoom, sy + zoom)))
    return [
        *actions,
        *((6, x, y) for x, y in sorted(points) if 0 <= x < 64 and 0 <= y < 64),
    ]


def components(points, eight=False):
    unseen = set(points)
    neighbors = [(dx, dy) for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1))]
    if eight:
        neighbors += [(1, 1), (1, -1), (-1, 1), (-1, -1)]
    answer = []
    while unseen:
        root = min(unseen)
        unseen.remove(root)
        frontier = [root]
        found = {root}
        while frontier:
            x, y = frontier.pop()
            for dx, dy in neighbors:
                candidate = (x + dx, y + dy)
                if candidate in unseen:
                    unseen.remove(candidate)
                    found.add(candidate)
                    frontier.append(candidate)
        answer.append(found)
    return answer
