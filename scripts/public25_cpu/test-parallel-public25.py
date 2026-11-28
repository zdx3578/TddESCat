"""Check allocation and scheduling without opening a game or requiring 27 physical CPUs."""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

source = Path(__file__).with_name("parallel-public25.py")
spec = importlib.util.spec_from_file_location("parallel_public25", source)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def verify_external_service():
    cpu = min(os.sched_getaffinity(0))
    with tempfile.TemporaryDirectory() as tmp:
        manager = Path(tmp) / "systemd-run"
        manager.write_text(
            '#!/bin/sh\nwhile test "$1" != "--"; do shift; done\nshift\nexec "$@"\n'
        )
        manager.chmod(0o755)
        for kind in ("--scope", "--service-type=exec"):
            command = [
                str(manager),
                kind,
                "--",
                sys.executable,
                "-c",
                "import os;print(sorted(os.sched_getaffinity(0)))",
            ]
            with runner.CaseSystemdProcesses(cpu).Popen(
                command, text=True, stdout=subprocess.PIPE
            ) as child:
                output, _ = child.communicate()
                assert child.returncode == 0 and json.loads(output) == [cpu]
    print("PASS scope and manager-spawned service execute on the assigned CPU")


def verify_dispatch():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        arms = {
            arm: {"game_ids": games, "root": tmp, "commit": arm}
            for arm, games in (
                (
                    "candidate",
                    [*runner.PAIR, *[f"g{i:03d}-aaaaaaaa" for i in range(23)]],
                ),
                ("baseline", list(runner.PAIR)),
            )
        }
        assigned = runner.cpu_assignment(arms, range(32))
        assert list(assigned.values()) == list(range(5, 32))
        try:
            runner.cpu_assignment(arms, range(24))
        except RuntimeError:
            pass
        else:
            raise AssertionError("The 24-core guest accepted 27 distinct assignments")
        plan = {"arms": arms, "runner_sha256": "fixture", "cpu_assignment": assigned}
        jobs = {}
        for arm, pin in arms.items():
            runner.write(
                root / arm / "manifest.json",
                {
                    **pin,
                    "runner_sha256": "fixture",
                    "online_runtime": {"enabled": True, "compiled": True},
                    "compute": {"capabilities": {"test": True}},
                    "qualified_at": 3,
                },
            )
            for g in pin["game_ids"]:
                (root / arm / g / "grade").mkdir(parents=True)
            jobs[arm] = {
                "state": "PREPARING",
                "process": SimpleNamespace(poll=lambda: 0),
            }
        fake_api = SimpleNamespace(
            atomic_json=runner.write,
            campaign_report=lambda games, rows: {"finished": len(rows)},
        )
        received = {}

        def launch(cmd, **kwargs):
            assert cmd[0] == "systemd-run"
            arm, g = cmd[-2:]
            key = f"{arm}/{g}"
            cpu = assigned[key]
            assert key not in received
            assert f"--property=CPUAffinity={cpu}" in cmd
            assert cmd[cmd.index("--") + 1 :] == [
                "/usr/bin/taskset",
                "--cpu-list",
                str(cpu),
                arm,
                g,
            ]
            received[key] = cmd
            if len(received) == 27:
                # Until the entire batch has a distinct service, no SDK is marked
                # ready and no case finishes. A spurious 2-slot dispatch cap hangs here.
                for key in received:
                    arm, g = key.split("/")
                    runner.write(
                        root / arm / g / "grade/runner-result.json",
                        {"game_id": g, "verdict": "NOT_WON"},
                    )
            return SimpleNamespace(returncode=0, stdout="accepted", stderr="")

        count = 0

        def poll(_):
            nonlocal count
            count += 1
            assert count < 4, "The outer coordinator is waiting for SDK starts"

        with (
            patch.object(runner, "api_for", return_value=fake_api),
            patch.object(
                runner,
                "room",
                return_value={
                    "memory_available_gib": 92,
                    "disk_available_gib": 190,
                    "vcpus": 32,
                    "load1": 4,
                },
            ),
            patch.object(runner.subprocess, "check_output", return_value=""),
            patch.object(runner.subprocess, "run", side_effect=launch),
            patch.object(
                runner,
                "child_command",
                side_effect=lambda a, rev, bu, out, mode, g: [a, g],
            ),
            patch.object(runner.time, "sleep", side_effect=poll),
        ):
            runner.launch_slots(root)
            assert (
                runner.schedule(SimpleNamespace(output=root, bundle=root), plan, jobs)
                == 0
            )
        assert (
            len(received) == 27
            and sum(k.startswith("candidate/") for k in received) == 25
        )
        print(
            "PASS 25 candidate and 2 baseline workers concurrently dispatched before any SDK readiness or completion"
        )
        print(
            "PASS guest CPUs 5 through 29 assigned to candidate, 30 and 31 to baseline"
        )


def verify_guest_systemd():
    # Run this optional qualification inside a real single-CPU user transient unit.
    allowed = sorted(os.sched_getaffinity(0))
    assert len(allowed) == 1, f"Expected a single pinned guest CPU, got {allowed}"
    cpu = allowed[0]
    measurements = {"evaluator": allowed}
    for name, flags in (
        ("solver_scope", ["--scope"]),
        ("stitch_service", ["--wait", "--pipe", "--service-type=exec"]),
    ):
        command = [
            "/usr/bin/systemd-run",
            "--user",
            "--quiet",
            "--collect",
            *flags,
            "--",
            "/usr/bin/bwrap",
            "--unshare-net",
            "--ro-bind",
            "/",
            "/",
            "--proc",
            "/proc",
            "--dev",
            "/dev",
            "--",
            "/usr/bin/python3",
            "-c",
            "import os;print(sorted(os.sched_getaffinity(0)))",
        ]
        with runner.CaseSystemdProcesses(cpu).Popen(
            command, stdout=subprocess.PIPE, text=True
        ) as proc:
            out, _ = proc.communicate()
            assert proc.returncode == 0 and json.loads(out) == [cpu]
            measurements[name] = json.loads(out)
    print(json.dumps(measurements, sort_keys=True))


if __name__ == "__main__":
    if sys.argv[1:] == ["--guest-systemd"]:
        verify_guest_systemd()
    elif not sys.argv[1:]:
        verify_external_service()
        verify_dispatch()
    else:
        raise SystemExit("usage: test-parallel-public25.py [--guest-systemd]")
