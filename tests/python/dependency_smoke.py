"""Exercise the pinned ARC toolkit and engine through their local HTTP API."""

import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Thread
from unittest.mock import patch

import requests
from arc_agi import Arcade, OperationMode
from arc_agi.server import create_app
from werkzeug.serving import make_server

GAME_ID = "envsmoke-v1"
GAME_SOURCE = """\
from arcengine import ARCBaseGame, GameAction, Level


class Envsmoke(ARCBaseGame):
    def __init__(self, seed=0):
        super().__init__("envsmoke-v1", [Level()], available_actions=[1, 6], seed=seed)

    def step(self):
        if self.action.id == GameAction.RESET:
            self.camera.background = 0
        elif self.action.id == GameAction.ACTION1:
            self.camera.background += 1
            if self.camera.background == 1:
                return
        elif self.action.id == GameAction.ACTION6:
            self.camera.background = 3
        self.complete_action()
"""


def check_http(root: Path) -> None:
    game_dir = root / "game"
    game_dir.mkdir()
    (game_dir / "metadata.json").write_text(
        json.dumps({"game_id": GAME_ID, "class_name": "Envsmoke"}), encoding="utf-8"
    )
    (game_dir / "envsmoke.py").write_text(GAME_SOURCE, encoding="utf-8")
    arcade = Arcade(
        operation_mode=OperationMode.OFFLINE,
        environments_dir=str(game_dir),
        recordings_dir=str(root / "recordings"),
    )
    app, _ = create_app(arcade)
    server = make_server("127.0.0.1", 0, app)
    thread = Thread(target=server.serve_forever)
    thread.start()
    try:
        with requests.Session() as client:
            client.trust_env = False
            base_url = f"http://127.0.0.1:{server.server_port}/api"

            def request(method, route, **kwargs):
                response = client.request(
                    method, f"{base_url}/{route}", timeout=5, **kwargs
                )
                response.raise_for_status()
                return response.json()

            games = request("GET", "games")
            assert [game["game_id"] for game in games] == [GAME_ID], games
            card = request("POST", "scorecard/open", json={})["card_id"]
            command = {"game_id": GAME_ID, "card_id": card}
            reset = request("POST", "cmd/RESET", json=command)
            assert reset["available_actions"] == [1, 6], reset["available_actions"]
            assert len(reset["frame"]) == 1 and reset["frame"][0][0][0] == 0
            command["guid"] = reset["guid"]
            move = request("POST", "cmd/ACTION1", json=command)
            assert move["guid"] == reset["guid"]
            assert move["action_input"]["id"] == 1
            assert move["frame"] == [
                [[color] * 64 for _ in range(64)] for color in (1, 2)
            ]
            click = request("POST", "cmd/ACTION6", json={**command, "x": 17, "y": 29})
            assert click["action_input"]["id"] == 6
            assert click["action_input"]["data"]["x"] == 17
            assert click["action_input"]["data"]["y"] == 29
            assert len(click["frame"]) == 1 and click["frame"][0][0][0] == 3
            request("POST", "scorecard/close", json={"card_id": card})
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


if __name__ == "__main__":
    environment = {
        key: value
        for key, value in os.environ.items()
        if key not in {"OPERATION_MODE", "ARC_API_KEY", "ARC_BASE_URL"}
    }
    with (
        patch.dict(os.environ, environment, clear=True),
        TemporaryDirectory() as directory,
    ):
        check_http(Path(directory))
    print(
        "Python HTTP smoke passed: discovery, scorecard, RESET, multi-frame ACTION1, ACTION6"
    )
