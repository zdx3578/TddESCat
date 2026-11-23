"""Loopback HTTP fault proxy over the fixed official toolkit."""

import json
import socket
from contextlib import closing
from hashlib import sha256
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from time import sleep

import requests
from arc_agi import Arcade, OperationMode
from arc_agi.server import create_app
from werkzeug.serving import make_server

GAME_ID = "ps00-00000001"
COOKIE_TOKEN = "test_affinity_private_value_921d"
ERROR_BYTES = b'{"error":"VALIDATION_ERROR","message":"injected"}\n'
GAME_SOURCE = """from arcengine import ARCBaseGame, GameAction, Level

class Probe(ARCBaseGame):
    def __init__(self, seed=0):
        super().__init__("ps00-00000001", [Level()], available_actions=list(range(1, 8)), seed=seed)

    def step(self):
        self.camera.background = (0 if self.action.id == GameAction.RESET
                                  else (self.camera.background + 1) % 16)
        self.complete_action()
"""


class FaultStub:
    def __init__(self, root: Path, mode: str):
        self.mode = mode
        self.trace = []
        root.mkdir(parents=True)
        game = root / "game"
        game.mkdir()
        (game / "probe.py").write_text(GAME_SOURCE, encoding="utf-8")
        (game / "metadata.json").write_text(
            json.dumps({"game_id": GAME_ID, "class_name": "Probe"}), encoding="utf-8"
        )
        arcade = Arcade(
            operation_mode=OperationMode.OFFLINE,
            environments_dir=str(game),
            recordings_dir=str(root / "recordings"),
        )
        app, _ = create_app(arcade, add_cookie=self._add_cookie)
        self.backend = make_server("127.0.0.1", 0, app)
        self.backend_url = f"http://127.0.0.1:{self.backend.server_port}"
        self.backend_thread = Thread(target=self.backend.serve_forever, daemon=True)
        self.proxy = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.proxy_thread = Thread(target=self.proxy.serve_forever, daemon=True)
        self.other_response = None

    @staticmethod
    def _add_cookie(response, _key):
        response.set_cookie("affinity", COOKIE_TOKEN, httponly=True)
        return response

    @property
    def url(self):
        return f"http://127.0.0.1:{self.proxy.server_port}"

    def __enter__(self):
        self.backend_thread.start()
        if self.mode == "wrong_guid":
            with requests.Session() as http:
                http.trust_env = False
                card = http.post(
                    self.backend_url + "/api/scorecard/open", json={}, timeout=5
                )
                card.raise_for_status()
                game = http.post(
                    self.backend_url + "/api/cmd/RESET",
                    json={"card_id": card.json()["card_id"], "game_id": GAME_ID},
                    timeout=5,
                )
                game.raise_for_status()
                other = http.post(
                    self.backend_url + "/api/cmd/ACTION1",
                    json={"game_id": GAME_ID, "guid": game.json()["guid"]},
                    timeout=5,
                )
                other.raise_for_status()
                self.other_response = other.content
        self.proxy_thread.start()
        return self

    def __exit__(self, *_):
        self.proxy.shutdown()
        self.proxy.server_close()
        self.proxy_thread.join()
        self.backend.shutdown()
        self.backend.server_close()
        self.backend_thread.join()

    def _handler(self):
        stub = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                self.forward()

            def do_POST(self):
                self.forward()

            def forward(self):
                route = self.path
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                cookie = self.headers.get("Cookie", "")
                trace = {
                    "method": self.command,
                    "path": route,
                    "request": json.loads(body) if body else None,
                    "request_sha256": sha256(body).hexdigest(),
                    "cookie_seen": COOKIE_TOKEN in cookie,
                    "backend_executed": False,
                }
                stub.trace.append(trace)

                action1 = route == "/api/cmd/ACTION1"
                mode = stub.mode
                cookie_required = (
                    mode == "coordinates"
                    and self.command == "POST"
                    and route != "/api/scorecard/open"
                )
                if (
                    action1
                    and mode == "before_400"
                    or cookie_required
                    and not trace["cookie_seen"]
                ):
                    status, payload, set_cookie = 400, ERROR_BYTES, None
                else:
                    with requests.Session() as http:
                        http.trust_env = False
                        forwarded = http.request(
                            self.command,
                            stub.backend_url + route,
                            data=body or None,
                            headers={
                                "Content-Type": "application/json",
                                "Cookie": cookie,
                            },
                            timeout=5,
                        )
                    status, payload = forwarded.status_code, forwarded.content
                    set_cookie = forwarded.headers.get("Set-Cookie")
                    trace["backend_executed"] = self.command == "POST" and status == 200
                    trace["backend_status"] = status
                    if status == 200 and route.startswith("/api/cmd/"):
                        trace["backend_frame_sha256"] = sha256(payload).hexdigest()

                    if (
                        action1
                        and mode in {"drop", "timeout"}
                        or mode == "drop_open"
                        and route == "/api/scorecard/open"
                        or mode == "drop_reset"
                        and route == "/api/cmd/RESET"
                    ):
                        trace["response"] = (
                            "delayed_then_closed" if mode == "timeout" else "dropped"
                        )
                        if mode == "timeout":
                            sleep(1.8)
                        with closing(self.connection):
                            self.connection.shutdown(socket.SHUT_RDWR)
                        self.close_connection = True
                        return
                    if action1 and mode == "after_400":
                        status, payload = 400, ERROR_BYTES
                    elif action1 and mode == "wrong_guid":
                        payload = stub.other_response
                    elif route.startswith("/api/cmd/") and status == 200:
                        obj = json.loads(payload)
                        if mode == "coordinates":
                            obj["frame"] = [row[:7] for row in obj["frame"][0][:5]]
                            obj["frame"] = [obj["frame"]]
                        elif action1 and mode == "animation":
                            obj["frame"] = [
                                [[4, 1, 5], [1, 4, 2]],
                                [[4, 8, 5], [1, 4, 2]],
                                [[4, 1, 5], [1, 4, 2]],
                            ]
                        elif route == "/api/cmd/ACTION2" and mode == "animation":
                            obj["frame"] = [[[1, 2], [3]]]
                        elif action1 and mode == "wrong_action":
                            obj["action_input"]["id"] = 4
                        elif (
                            route == "/api/cmd/ACTION6" and mode == "wrong_coordinates"
                        ):
                            obj["action_input"]["data"]["x"] += 1
                        elif action1 and mode == "domain":
                            obj["available_actions"].remove(1)
                        elif action1 and mode == "missing_domain":
                            del obj["available_actions"]
                        payload = json.dumps(obj).encode()

                trace["http_status"] = status
                trace["response_sha256"] = sha256(payload).hexdigest()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                if set_cookie is not None:
                    self.send_header("Set-Cookie", set_cookie)
                self.end_headers()
                try:
                    self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        return Handler
