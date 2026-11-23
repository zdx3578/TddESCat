"""Check P01–P08 against the production Julia client and transaction store."""

import json
import subprocess
import sys
from contextlib import ExitStack
from pathlib import Path

from tddesc_tools.contracts import Contracts
from tddesc_tools.run import (
    append_assertion,
    julia_command,
    julia_environment,
    read_task,
    runtime_paths,
    write_json,
)
from tests.protocol_stub.server import COOKIE_TOKEN, GAME_ID, FaultStub

OPEN = {"op": "open"}
RESET = {"op": "reset", "game_id": GAME_ID}
CLOSE = {"op": "close"}


def action(id_, **kwargs):
    return {"op": "action", "id": id_, **kwargs}


STANDARD = [OPEN, RESET]
PROTOCOL_PLANS = (
    (
        "P01-click",
        "coordinates",
        [
            *STANDARD,
            action(6, x=17, y=29),
            action(6, x=0, y=63),
            action(6, x=3, y=2, origin_x=49, origin_y=0),
            CLOSE,
        ],
    ),
    ("P02-drop", "drop", [*STANDARD, action(1), action(1), action(2)]),
    ("P02-timeout", "timeout", [*STANDARD, action(1), action(2)]),
    (
        "P03-local",
        "normal",
        [
            *STANDARD,
            action(6, x=True, y=0),
            action(6, x=1.0, y=0),
            action(6, x=64, y=0),
            action(0),
            action(1),
        ],
    ),
    ("P03-before", "before_400", [*STANDARD, action(1), action(2)]),
    ("P03-after", "after_400", [*STANDARD, action(1), action(2)]),
    ("P04-frames", "animation", [*STANDARD, action(1), action(2)]),
    ("P05-guid", "wrong_guid", [*STANDARD, action(1)]),
    ("P05-action", "wrong_action", [*STANDARD, action(1)]),
    ("P05-coordinates", "wrong_coordinates", [*STANDARD, action(6, x=17, y=29)]),
    ("P06-card", "drop_open", [OPEN, OPEN, RESET, action(1)]),
    ("P06-reset", "drop_reset", [*STANDARD, RESET, action(1)]),
    ("P08-domain", "domain", [*STANDARD, action(1), action(1), action(2)]),
    ("P08-missing", "missing_domain", [*STANDARD, action(1), action(2)]),
)


class Result:
    def __init__(self, public, stub, contracts):
        self.public = public
        self.trace = list(stub.trace)
        self.commands = self.load("commands", "command", contracts)
        self.events = self.load("events", "event", contracts)
        self.predictions = self.load("predictions", "prediction", contracts)

    def load(self, folder, schema, contracts):
        items = []
        for path in sorted((self.public / folder).glob("*.json")):
            data = json.loads(path.read_bytes())
            contracts.validate(schema, data)
            items.append(data)
        return sorted(items, key=lambda item: item.get("sequence", 0))

    def sent(self, route):
        return [row for row in self.trace if row["path"] == route]

    @property
    def actions(self):
        return [cmd for cmd in self.commands if cmd["kind"] == "action"]

    def blob(self, event):
        return json.loads((self.public / "blobs" / event["response_blob"]).read_bytes())


def verify_unknown(case, reason=None):
    first, *later = case.actions
    assert first["completion"] == "outcome_unknown", first
    if reason is not None:
        assert first["reason"] == reason, first
    assert len(case.events) == 1 and case.events[0]["action"]["id"] == 0
    assert all(row.get("reason") == "session_quarantined" for row in later)
    assert len([r for r in case.trace if "/ACTION" in r["path"]]) == 1


def checks(results):
    p01 = results["P01-click"]
    clicks = p01.sent("/api/cmd/ACTION6")
    assert [(r["request"]["x"], r["request"]["y"]) for r in clicks] == [
        (17, 29),
        (0, 63),
        (52, 2),
    ]
    assert (
        all(r["cookie_seen"] for r in clicks)
        and p01.sent("/api/cmd/RESET")[0]["cookie_seen"]
    )
    assert "competition_mode" not in p01.sent("/api/scorecard/open")[0]["request"]
    assert all(c["completion"] == "confirmed" for c in p01.commands)
    assert len(p01.events) == 4 and all(
        e["frame_shapes"] == [[5, 7]] for e in p01.events
    )
    assert "guid" not in p01.sent("/api/cmd/RESET")[0]["request"]
    assert all(
        r["request_sha256"] == c["request_sha256"]
        for r, c in zip(p01.trace, p01.commands, strict=True)
    )
    assert all(
        COOKIE_TOKEN.encode() not in f.read_bytes()
        for f in p01.public.rglob("*")
        if f.is_file()
    )
    yield "P01", ["P01-click"]

    for name in ("P02-drop", "P02-timeout"):
        case = results[name]
        verify_unknown(case, "transport_or_storage")
        assert case.sent("/api/cmd/ACTION1")[0]["backend_executed"]
    yield "P02", ["P02-drop", "P02-timeout"]

    local = results["P03-local"]
    assert [x["completion"] for x in local.actions] == ["explicit_rejection"] * 4 + [
        "confirmed"
    ]
    assert not local.sent("/api/cmd/ACTION6") and not local.sent("/api/cmd/ACTION0")
    before, after = results["P03-before"], results["P03-after"]
    trace = [case.sent("/api/cmd/ACTION1")[0] for case in (before, after)]
    assert not trace[0]["backend_executed"] and trace[1]["backend_executed"]
    assert trace[0]["response_sha256"] == trace[1]["response_sha256"]
    for case in (before, after):
        verify_unknown(case, "http_status")
        assert (
            case.actions[0]["http_status"] == 400
            and "response_blob" not in case.actions[0]
        )
    yield "P03", ["P03-local", "P03-before", "P03-after"]

    frames = results["P04-frames"]
    assert [x["completion"] for x in frames.actions] == ["confirmed", "outcome_unknown"]
    assert len(frames.events) == 2 and frames.events[1]["frame_count"] == 3
    data = frames.blob(frames.events[1])
    assert data["frame"][0] == data["frame"][2] != data["frame"][1]
    assert frames.actions[1]["reason"] == "nonrectangular_frame"
    yield "P04", ["P04-frames"]

    keys = ["P05-guid", "P05-action", "P05-coordinates"]
    for key, reason in zip(
        keys, ["guid_mismatch", "action_mismatch", "coordinates_mismatch"], strict=True
    ):
        verify_unknown(results[key], reason)
    yield "P05", keys

    for name, lost in (
        ("P06-card", "/api/scorecard/open"),
        ("P06-reset", "/api/cmd/RESET"),
    ):
        case = results[name]
        assert len(case.sent(lost)) == 1 and case.sent(lost)[0]["backend_executed"]
        records = [x for x in case.commands if x["path"] == lost]
        assert records[0]["completion"] == "outcome_unknown"
        assert records[1]["reason"] == "session_quarantined"
        assert not case.events and not case.sent("/api/cmd/ACTION1")
    yield "P06", ["P06-card", "P06-reset"]

    yield "P07", ["P07-confirmed", "P07-receipt", "P07-sent"]

    domain = results["P08-domain"]
    assert [x["completion"] for x in domain.actions] == [
        "confirmed",
        "explicit_rejection",
        "confirmed",
    ]
    assert domain.actions[1]["reason"] == "action_unavailable"
    assert (
        len(domain.sent("/api/cmd/ACTION1"))
        == len(domain.sent("/api/cmd/ACTION2"))
        == 1
    )
    assert 1 not in domain.blob(domain.events[1])["available_actions"]
    verify_unknown(results["P08-missing"], "invalid_available_actions")
    yield "P08", ["P08-domain", "P08-missing"]


def configure_plan(run_dir, name, url, ops, template):
    public = run_dir / "public/protocol" / name
    public.mkdir(parents=True)
    config = public / "agent.toml"
    config.write_text(
        template.replace("http://127.0.0.1:43191", url)
        .replace("max_public_commands = 2", "max_public_commands = 40")
        .replace("request_timeout_seconds = 5.0", "request_timeout_seconds = 1.3"),
        encoding="utf-8",
    )
    return {"config": str(config), "public": str(public), "ops": ops}


def run_julia(root, runtime, *args):
    cmd = julia_command(root, runtime, root / "tests/julia/protocol_driver.jl", *args)
    result = subprocess.run(
        cmd, env=julia_environment(runtime), capture_output=True, text=True
    )
    return result


def crash_checks(root, runtime, run_dir, contracts, template):
    for stage in ("confirmed", "receipt", "sent"):
        key = f"P07-{stage}"
        with FaultStub(run_dir / "private" / key, "normal") as stub:
            sent_ops = [*STANDARD, action(1, crash_at=stage)]
            plan = configure_plan(run_dir, key, stub.url, sent_ops, template)
            public = Path(plan["public"])
            path = public / "plan.json"
            write_json(path, [plan])
            crashed = run_julia(root, runtime, path)
            assert crashed.returncode == 79, crashed.stderr
            case = Result(public, stub, contracts)
            assert len(case.sent("/api/cmd/ACTION1")) == int(stage != "sent"), (
                case.trace
            )
            expected = 1 if stage == "sent" else 2
            recoveries = []
            for count in (expected, 0):
                replayed = run_julia(root, runtime, "--replay", public)
                assert replayed.returncode == 0, replayed.stderr
                replay = json.loads(replayed.stdout.splitlines()[-1])
                assert replay["applied"] == count and replay["total"] == expected
                recoveries.append(replay)
            after = Result(public, stub, contracts)
            assert after.trace == case.trace and len(after.events) == expected
            assert len({event["event_id"] for event in after.events}) == expected
            assert after.actions[0]["completion"] == (
                "outcome_unknown" if stage == "sent" else "confirmed"
            )
            assert recoveries[0]["through_event"] == recoveries[1]["through_event"]
            write_json(run_dir / "private" / key / "trace.json", after.trace)
            write_json(public / "recovery.json", recoveries)


def main(config, run_dir):
    root = Path.cwd()
    runtime = runtime_paths(root)
    contracts = Contracts(root / "protocol/v1")
    config = read_task(config)
    template = config["agent_config"].read_text(encoding="utf-8")
    results = {}
    with ExitStack() as resources:
        plans = []
        stubs = {}
        for name, fault, ops in PROTOCOL_PLANS:
            stub = resources.enter_context(FaultStub(run_dir / "private" / name, fault))
            plans.append(configure_plan(run_dir, name, stub.url, ops, template))
            stubs[name] = stub
        path = run_dir / "public/protocol/driver.json"
        write_json(path, plans)
        outcome = run_julia(root, runtime, path)
        (run_dir / "grade/julia.log").write_text(
            outcome.stdout + outcome.stderr, encoding="utf-8"
        )
        for plan, (name, _, _) in zip(plans, PROTOCOL_PLANS, strict=True):
            write_json(run_dir / "private" / name / "trace.json", stubs[name].trace)
            results[name] = Result(Path(plan["public"]), stubs[name], contracts)
        assert outcome.returncode == 0, outcome.stderr
    crash_checks(root, runtime, run_dir, contracts, template)
    for identifier, names in checks(results):
        append_assertion(
            run_dir, identifier, True, [f"public/protocol/{key}" for key in names]
        )


if __name__ == "__main__":
    main(*(Path(arg) for arg in sys.argv[1:]))
