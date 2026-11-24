"""Validate the published real-interface learning chain."""

import json
import re
import sys
import tomllib
from hashlib import sha256
from importlib.metadata import version
from pathlib import Path

from tddesc_tools.isolation import environment_server, isolation_probe
from tddesc_tools.public_run import (
    SUPERVISOR_BLOCKED,
    public_settings,
    solver_command,
    supervise,
)
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json


def offline_capture(root, task, run):
    public = run / "public"
    private = run / "private"
    bundle = task["offline_bundle"]
    catalog = bundle / "offline_public_games_manifest.json"
    games = bundle / "environment_files"
    if not catalog.is_file() or not games.is_dir():
        write_json(
            public / "supervision.json",
            {"state": "BLOCKED", "reason": "missing_official_offline_bundle"},
        )
        return SUPERVISOR_BLOCKED
    runtime = runtime_paths(root)
    original = task["agent_config"]
    text = original.read_text(encoding="utf-8")
    values = tomllib.loads(text)
    game = values["environment"]["game_id"]
    base, revision = game.split("-", 1)
    if not re.fullmatch(r"[a-z0-9]{4}", base) or not re.fullmatch(
        r"[a-f0-9]{8}", revision
    ):
        raise ValueError("Expected a versioned official game id")
    game_dir = games / base / revision
    metadata = game_dir / "metadata.json"
    game_file = game_dir / (base + ".py")
    assert json.loads(metadata.read_bytes())["game_id"] == game
    write_json(
        public / "arc-source.json",
        {
            "environment": "official_offline_http",
            "game_id": game,
            "game_source_sha256": sha256(game_file.read_bytes()).hexdigest(),
            "metadata_sha256": sha256(metadata.read_bytes()).hexdigest(),
            "catalog_sha256": sha256(catalog.read_bytes()).hexdigest(),
            "toolkit": version("arc-agi"),
            "engine": version("arcengine"),
        },
    )
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        private / "server",
        run / "grade/environment.log",
    ) as (url, server_pid):
        agent = public / "agent.toml"
        engine = (original.parent / values["learning"]["engine"]).resolve()
        projection = re.sub(
            r"(?m)^base_url\s*=.*$", f"base_url = {json.dumps(url)}", text
        )
        projection = re.sub(
            r"(?m)^engine\s*=.*$", f"engine = {json.dumps(str(engine))}", projection
        )
        policy = (original.parent / values["learning"]["policy_file"]).resolve()
        projection = re.sub(
            r"(?m)^policy_file\s*=.*$",
            f"policy_file = {json.dumps(str(policy))}",
            projection,
        )
        agent.write_text(projection, encoding="utf-8")
        paths = public_settings(root, agent, tomllib.loads(projection))
        probe = isolation_probe(
            root,
            url,
            game_file,
            private,
            server_pid,
            launch=lambda command: solver_command(
                root, runtime, agent, public, paths, command=command
            ),
        )
        write_json(public / "solver-isolation.json", probe)
        return supervise(root, agent, public, expected_paths=paths)


def main(config, run):
    root = Path.cwd()
    task = read_task(config)
    public = run / "public"
    offline = task["kind"] == "arc_offline"
    code = (
        offline_capture(root, task, run)
        if offline
        else supervise(root, task["agent_config"], public)
    )
    status = json.loads((public / "supervision.json").read_bytes())
    identifier = "public_learning_loop"
    if code == SUPERVISOR_BLOCKED:
        append_assertion(
            run, identifier, None, ["public/supervision.json"], status["reason"]
        )
        return code
    if code:
        append_assertion(
            run,
            identifier,
            False,
            ["public/supervision.json"],
            f"public_capture_exit:{code}",
        )
        return 1
    events = {
        row["event_id"]: row
        for path in (public / "events").glob("*.json")
        if (row := json.loads(path.read_bytes()))["completion"] == "confirmed"
    }
    checks = [
        json.loads(path.read_bytes()) for path in (public / "checks").glob("*.json")
    ]
    publications = json.loads((public / "public-run.json").read_bytes())["learned"][
        "publications"
    ]
    for digest in publications:
        path = public / "publication" / f"{digest}.json"
        artifact = json.loads(path.read_bytes())
        definitions = set(artifact["new_definition_ids"])
        sources = {o["event_ref"] for o in artifact["origins"]}
        if not definitions or not sources or not sources <= events.keys():
            continue
        last_source = max(events[ref]["sequence"] for ref in sources)
        for checked in sorted(
            checks, key=lambda row: events[row["event_ref"]]["sequence"]
        ):
            support = checked["assessments"]
            used = definitions.intersection(checked["definition_refs"])
            if (
                last_source < events[checked["event_ref"]]["sequence"]
                and used
                and support
                and set(support.values()) == {"supported"}
            ):
                consumed = events[checked["event_ref"]]
                command = json.loads(
                    (
                        public / "commands" / (consumed["command_ref"] + ".json")
                    ).read_bytes()
                )
                prediction = (
                    public / "predictions" / (command["prediction_ref"] + ".json")
                )
                assert prediction.is_file() and command["completion"] == "confirmed"
                assert (
                    sha256(
                        (public / "blobs" / consumed["response_blob"]).read_bytes()
                    ).hexdigest()
                    == consumed["response_blob"]
                )
                audited = {
                    occ
                    for call in artifact["calls"]
                    if call["definition_ref"] in used
                    for occ in call["source_occurrences"]
                }
                used_sources = {
                    row["event_ref"]
                    for row in artifact["origins"]
                    if row["occurrence_id"] in audited
                }
                assert used_sources and used_sources <= sources
                summary = {
                    "definition_refs": sorted(used),
                    "source_events": sorted(used_sources),
                    "consumption_event": checked["event_ref"],
                    "command_ref": command["command_id"],
                    "action": checked["action"],
                    "confirmed_response_sha256": consumed["response_blob"],
                    "assessments": support,
                    "publication": digest,
                    "recorded_events": len(events),
                    "supported_predictions": sum(
                        bool(row["assessments"])
                        and set(row["assessments"].values()) == {"supported"}
                        for row in checks
                    ),
                    "refuted_predictions": sum(
                        "refuted" in row["assessments"].values() for row in checks
                    ),
                }
                write_json(public / "verified-chain.json", summary)
                append_assertion(
                    run,
                    identifier,
                    True,
                    [
                        "public/verified-chain.json",
                        path.relative_to(run).as_posix(),
                        prediction.relative_to(run).as_posix(),
                        *(
                            ["public/arc-source.json", "public/solver-isolation.json"]
                            if offline
                            else []
                        ),
                    ],
                )
                return 0
    append_assertion(
        run,
        identifier,
        False,
        ["public/public-run.json"],
        "no_real_discovery_to_confirmed_consumption_chain",
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
