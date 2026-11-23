"""Finite reference transitions and public-frame oracle independent of ARCEngine."""

from collections import deque

from .scenario import Scene, State


def transition(scene: Scene, state: State, action: int) -> State:
    if action == 0:
        return scene.start_state
    if action == 5 and scene.switch:
        return State(state.positions, not state.switch_on)
    positions = state.positions
    mapping = [(dx, dy) for number, dx, dy in scene.moves if number == action]
    if len(mapping) != 1:
        raise ValueError("Action outside finite domain")
    if not positions:
        return state
    if scene.path_policy == "swap":
        return State(positions[::-1], state.switch_on)

    left, top, right, bottom = scene.active
    floor = {(x, y) for y in range(top, bottom) for x in range(left, right)}
    floor.difference_update(scene.blocked, scene.holes)
    if scene.switch and state.switch_on is False:
        floor.difference_update(scene.switch.gate_cells)
    for i in range(1, len(positions)):
        for x, y, _ in scene.bodies[i]:
            floor.discard((positions[i][0] + x, positions[i][1] + y))

    delta_x, delta_y = mapping[0]
    anchor_x, anchor_y = positions[0]
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
    allowed = all(
        (x + u, y + v) in floor for x, y in path for u, v, _ in scene.bodies[0]
    )
    return State((end, *positions[1:]), state.switch_on) if allowed else state


def logical_colors(scene, state):
    colors = {(x, y): color for x, y, color in scene.static}
    if scene.switch:
        left, top = scene.switch.panel
        color = scene.switch.on_color if state.switch_on else scene.switch.off_color
        for x in range(left, left + 2):
            for y in range(top, top + 2):
                colors[x, y] = color
    for (x, y), body in zip(state.positions, scene.bodies, strict=True):
        colors.update({(x + u, y + v): color for u, v, color in body})
    return colors


def screen_geometry(scene):
    left, top, width, height = scene.viewport
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


def render(scene: Scene, state: State):
    colors = logical_colors(scene, state)
    left, top, width, height, scale, start_x, start_y = screen_geometry(scene)
    screen = [[scene.letterbox] * 64 for _ in range(64)]
    for y in range(height):
        for x in range(width):
            color = colors.get((left + x, top + y), scene.background)
            dest_x, dest_y = start_x + x * scale, start_y + y * scale
            for row in range(dest_y, dest_y + scale):
                screen[row][dest_x : dest_x + scale] = [color] * scale
    return screen


def reachable(scene):
    frontier = deque([scene.start_state])
    seen = {scene.start_state}
    while frontier:
        state = frontier.popleft()
        yield state
        for action in scene.actions:
            candidate = transition(scene, state, action)
            if candidate not in seen:
                seen.add(candidate)
                frontier.append(candidate)


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
