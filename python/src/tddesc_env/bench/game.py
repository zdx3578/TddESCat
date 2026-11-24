"""Synthetic moves exposed through the official ARC engine."""

import numpy as np
from arcengine import ARCBaseGame, Camera, GameAction, Level, Sprite

from .scenario import Scene, State


class ShapeGame(ARCBaseGame):
    def __init__(self, scene: Scene):
        self.scene = scene
        self.positions = list(scene.start)
        self.switch_on = scene.start_state.switch_on
        self.resource = scene.start_state.resource
        self.selected = scene.initial_selection
        self.flagged = False
        self.previous_positions = None
        self.animation_frame = 0
        self._moves = {number: (dx, dy) for number, dx, dy in scene.moves}
        x0, y0, width, height = scene.viewport
        camera = Camera(
            x=x0,
            y=y0,
            width=width,
            height=height,
            background=scene.background,
            letter_box=scene.letterbox,
        )
        width, height = scene.logical_size
        sprite = Sprite(np.full((height, width), -1, dtype=np.int8), name="paint")
        super().__init__(
            scene.public_id,
            [Level(sprites=[sprite])],
            camera=camera,
            available_actions=list(scene.actions),
            seed=scene.seed,
        )

    def _footprint(self, role, x, y):
        return {(x + dx, y + dy) for dx, dy, _ in self.scene.bodies[role]}

    def _can_fit(self, support):
        scene = self.scene
        left, top, right, bottom = scene.active
        occupied = set(scene.blocked) | set(scene.holes)
        gate_open = (
            self.flagged
            if scene.dynamics in ("latched", "flash", "flash-closed")
            else self.switch_on
        )
        if scene.switch and not gate_open:
            occupied.update(scene.switch.gate_cells)
        return not support & occupied and all(
            left <= u < right and top <= v < bottom for u, v in support
        )

    def _shift(self, dx, dy):
        scene = self.scene
        if scene.path_policy == "swap":
            self.positions.reverse()
            return
        role = self.selected
        x, y = self.positions[role]
        proposed = (x + dx, y + dy)
        others = {
            i: self._footprint(i, *pos)
            for i, pos in enumerate(self.positions)
            if i != role
        }
        if scene.path_policy == "swept":
            steps = max(abs(dx), abs(dy))
            for distance in range(1, steps + 1):
                support = self._footprint(
                    role, x + dx * distance // steps, y + dy * distance // steps
                )
                if not self._can_fit(support) or any(
                    support & cells for cells in others.values()
                ):
                    return
        target = self._footprint(role, *proposed)
        if not self._can_fit(target):
            return
        entering = target - self._footprint(role, x, y)
        consumes = scene.resource is not None and bool(
            entering.intersection(scene.resource.gate_cells)
        )
        if consumes and self.resource == 0:
            return
        collisions = [i for i, support in others.items() if target & support]
        if collisions:
            if not scene.pushable or len(collisions) != 1:
                return
            pushed = collisions[0]
            u, v = self.positions[pushed]
            following = (u + dx, v + dy)
            shifted = self._footprint(pushed, *following)
            if (
                not self._can_fit(shifted)
                or target & shifted
                or any(
                    shifted & support for i, support in others.items() if i != pushed
                )
            ):
                return
            self.positions[pushed] = following
        self.positions[role] = proposed
        if consumes:
            self.resource -= 1

    def _click(self):
        target = self.camera.display_to_grid(
            self.action.data["x"], self.action.data["y"]
        )
        matches = [
            i
            for i, pos in enumerate(self.positions)
            if target in self._footprint(i, *pos)
        ]
        if len(matches) == 1:
            self.selected = matches[0]

    def snapshot(self):
        return State(
            tuple(self.positions),
            self.switch_on,
            self.resource,
            self.selected,
            self.flagged,
            self.previous_positions,
        )

    def restore(self, state):
        self.positions = list(state.positions)
        self.switch_on = state.switch_on
        self.resource = state.resource
        self.selected = state.selected
        self.flagged = state.flagged
        self.previous_positions = state.previous_positions
        self._available_actions = list(self.scene.actions)
        if self.scene.dynamics == "action-domain" and self.flagged:
            self._available_actions.remove(1)
        self._update_camera()

    def _update_camera(self):
        origin = self.scene.tracking_origin
        if origin is None and self.scene.dynamics == "tracking":
            origin = 18
        if origin is not None:
            maximum = self.scene.logical_size[0] - self.scene.viewport[2]
            self.camera.x = min(maximum, max(0, self.positions[0][0] - origin))

    def step(self):
        scene = self.scene
        action = self.action.id.value
        mode = scene.dynamics
        if action == 5 and mode in ("latched", "flash", "flash-closed"):
            self.flagged = mode != "flash-closed"
            self._render(
                display_offset=1
                if mode.startswith("flash") and self.animation_frame == 0
                else 0,
                flash=self.animation_frame == 1 and scene.signal is not None,
            )
            self.animation_frame += 1
            if self.animation_frame == 3:
                self.animation_frame = 0
                self.complete_action()
            return
        before = tuple(self.positions)
        if self.action.id == GameAction.RESET:
            self.restore(scene.start_state)
        elif action == 7:
            had_history = self.previous_positions is not None
            if self.previous_positions is not None:
                if mode == "undo-first":
                    self.positions[0] = self.previous_positions[0]
                else:
                    self.positions = list(self.previous_positions)
            self.previous_positions = None
            self.flagged = mode != "undo-with-token" or (
                had_history and self.resource == 0
            )
        elif action == 5 and mode == "decoy-switch":
            self.flagged = not self.flagged
        elif self.action.id == GameAction.ACTION5 and self.scene.switch:
            self.switch_on = not self.switch_on
        elif self.action.id == GameAction.ACTION5 and self.scene.resource:
            self.resource = max(0, self.resource - 1)
        elif (
            self.action.id == GameAction.ACTION6
            and self.scene.selection_color is not None
        ):
            self._click()
        elif self.positions and action in self._moves:
            self._shift(*self._moves[action])
            if tuple(self.positions) != before and mode.startswith("undo-"):
                self.previous_positions = before
            if tuple(self.positions) != before and mode in (
                "latched",
                "flash",
                "flash-closed",
            ):
                self.flagged = False
        if action != 0:
            if mode == "charge-still" and action == 1:
                self.resource = max(0, self.resource - 1)
            elif mode == "action-domain" and action == 1 and not self.flagged:
                self.flagged = True
                self._available_actions.remove(1)
            elif mode == "autonomous":
                x, y = self.positions[1]
                self.positions[1] = min(x + 1, self.scene.logical_size[0] - 1), y
        self._update_camera()
        self._render()
        if (
            action != 0
            and scene.goal is not None
            and (
                not scene.goal_with_signal
                or (self.flagged and self.selected == scene.goal_role)
            )
        ):
            x, y = scene.goal
            role = scene.goal_role
            if any(
                0 < abs(u - x) + abs(v - y) <= scene.goal_distance
                for u, v in self._footprint(role, *self.positions[role])
            ):
                self.next_level()
        self.complete_action()

    def _render(self, *, display_offset=0, flash=False):
        view = self.current_level.get_sprites()[0].pixels
        view.fill(-1)
        for x, y, color in self.scene.static:
            view[y, x] = color
        if self.scene.switch:
            panel = self.scene.switch
            x, y = panel.panel
            view[y : y + 2, x : x + 2] = (
                panel.on_color if self.switch_on else panel.off_color
            )
        if self.scene.resource:
            x, y = self.scene.resource.panel
            for i in range(self.resource):
                view[y, x + i * 2] = self.scene.resource.color
        if self.scene.signal is not None and (
            flash
            or (
                self.flagged
                and (
                    self.scene.dynamics.startswith("undo-")
                    or self.scene.dynamics == "decoy-switch"
                )
            )
        ):
            x, y, color = self.scene.signal
            view[y, x] = color
        if self.scene.selection_color is not None:
            x, y = self.positions[self.selected]
            width, height = self.scene.logical_size
            for u, v in self._border(x, y):
                if 0 <= u < width and 0 <= v < height:
                    view[v, u] = self.scene.selection_color
        for role, (shape, (x, y)) in enumerate(
            zip(self.scene.bodies, self.positions, strict=True)
        ):
            for dx, dy, color in shape:
                pixel = x + dx + (display_offset if role == 0 else 0)
                if pixel < view.shape[1]:
                    view[y + dy, pixel] = color

    @staticmethod
    def _border(x, y):
        for dx in (-1, 0, 1, 2):
            for dy in (-1, 0, 1, 2):
                if dx in (-1, 2) or dy in (-1, 2):
                    yield x + dx, y + dy
