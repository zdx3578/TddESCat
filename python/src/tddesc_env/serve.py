"""Load local games and expose the pinned toolkit's official HTTP application."""

import argparse
import json
import tomllib
from pathlib import Path

from arc_agi import Arcade, OperationMode
from arc_agi.server import create_app
from werkzeug.serving import make_server


def server_config(path):
    values = tomllib.loads(path.read_text(encoding="utf-8"))
    if (
        values.keys() != {"schema_version", "host", "port"}
        or type(values["schema_version"]) is not int
        or values["schema_version"] != 1
        or values["host"] != "127.0.0.1"
        or type(values["port"]) is not int
        or not 0 <= values["port"] <= 65535
    ):
        raise ValueError("Unsupported benchmark server configuration")
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--games", required=True, type=Path)
    parser.add_argument("--work", required=True, type=Path)
    args = parser.parse_args()
    config = server_config(args.config)
    args.work.mkdir(parents=True, exist_ok=True)
    arcade = Arcade(
        operation_mode=OperationMode.OFFLINE,
        environments_dir=str(args.games.resolve()),
        recordings_dir=str((args.work / "recordings").resolve()),
    )
    app, _ = create_app(arcade)
    with make_server(config["host"], config["port"], app) as server:
        ready = args.work / "ready.tmp"
        ready.write_text(
            json.dumps({"port": server.server_port}) + "\n", encoding="utf-8"
        )
        ready.replace(args.work / "ready.json")
        server.serve_forever()


if __name__ == "__main__":
    main()
