"""Synthetic moves exposed through the official ARC engine."""

import numpy as np
from arcengine import ARCBaseGame, Camera, GameAction, Level, Sprite

from .scenario import Scene


class ShapeGame(ARCBaseGame):
    def __init__(self, scene: Scene):
        self.scene = scene
        self.positions = list(scene.start)
        self.switch_on = scene.start_state.switch_on
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

    def _can_fit(self, x, y):
        scene = self.scene
        left, top, right, bottom = scene.active
        support = {(x + dx, y + dy) for dx, dy, _ in scene.bodies[0]}
        occupied = set(scene.blocked) | set(scene.holes)
        if scene.switch and not self.switch_on:
            occupied.update(scene.switch.gate_cells)
        for shape, (other_x, other_y) in zip(
            scene.bodies[1:], self.positions[1:], strict=True
        ):
            occupied.update((other_x + dx, other_y + dy) for dx, dy, _ in shape)
        return not support & occupied and all(
            left <= u < right and top <= v < bottom for u, v in support
        )

    def _shift(self, dx, dy):
        if self.scene.path_policy == "swap":
            self.positions.reverse()
            return
        x, y = self.positions[0]
        if self.scene.path_policy == "swept":
            steps = max(abs(dx), abs(dy))
            for distance in range(1, steps + 1):
                if not self._can_fit(
                    x + dx * distance // steps, y + dy * distance // steps
                ):
                    return
        if self._can_fit(x + dx, y + dy):
            self.positions[0] = (x + dx, y + dy)

    def step(self):
        if self.action.id == GameAction.RESET:
            self.positions = list(self.scene.start)
            self.switch_on = self.scene.start_state.switch_on
        elif self.action.id == GameAction.ACTION5 and self.scene.switch:
            self.switch_on = not self.switch_on
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
        for shape, (x, y) in zip(self.scene.bodies, self.positions, strict=True):
            for dx, dy, color in shape:
                view[y + dy, x + dx] = color
        self.complete_action()
