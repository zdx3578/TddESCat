"""Synthetic moves exposed through the official ARC engine."""

import numpy as np
from arcengine import ARCBaseGame, Camera, GameAction, Level, Sprite

from .scenario import Scene


class ShapeGame(ARCBaseGame):
    def __init__(self, scene: Scene):
        self.scene = scene
        self.positions = list(scene.start)
        self.switch_on = scene.start_state.switch_on
        self.resource = scene.start_state.resource
        self.selected = scene.initial_selection
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
        if scene.switch and not self.switch_on:
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

    def step(self):
        if self.action.id == GameAction.RESET:
            self.positions = list(self.scene.start)
            self.switch_on = self.scene.start_state.switch_on
            self.resource = self.scene.start_state.resource
            self.selected = self.scene.initial_selection
        elif self.action.id == GameAction.ACTION5 and self.scene.switch:
            self.switch_on = not self.switch_on
        elif self.action.id == GameAction.ACTION5 and self.scene.resource:
            self.resource = max(0, self.resource - 1)
        elif (
            self.action.id == GameAction.ACTION6
            and self.scene.selection_color is not None
        ):
            self._click()
        elif self.positions and self.action.id.value in self._moves:
            self._shift(*self._moves[self.action.id.value])
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
        if self.scene.selection_color is not None:
            x, y = self.positions[self.selected]
            width, height = self.scene.logical_size
            for u, v in self._border(x, y):
                if 0 <= u < width and 0 <= v < height:
                    view[v, u] = self.scene.selection_color
        for shape, (x, y) in zip(self.scene.bodies, self.positions, strict=True):
            for dx, dy, color in shape:
                view[y + dy, x + dx] = color
        self.complete_action()

    @staticmethod
    def _border(x, y):
        for dx in (-1, 0, 1, 2):
            for dy in (-1, 0, 1, 2):
                if dx in (-1, 2) or dy in (-1, 2):
                    yield x + dx, y + dy
