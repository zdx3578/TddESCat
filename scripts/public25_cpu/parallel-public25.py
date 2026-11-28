#!/usr/bin/env python3
"""Operator launcher. All game actions, transport recovery and verification use the pinned checkout."""

import argparse
from contextlib import contextmanager
import fcntl
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import time
import tomllib

HERE = Path(__file__).resolve()
CHECKOUTS = Path("/home/zdx/github/VSAHDC/worktree")
DEFAULT_BUNDLE = Path("/home/solver/fixtures/public25")
ARCHIVE = Path("/home/solver/v13-runtime/stage/public25.tar.gz")
ARCHIVE_SHA = "db50202cfcf715f381564d07513c3e6d7a553edee13de19dd1d2cca6dd8996e1"
CATALOG_SHA = "a5fcdafbb23be6b83afd4bb78bbc7054d502eddac8de2dbcc34c561384a6f868"
PROFILE_SHA = "7871b942129df432942754af590c53014f155bd867290bdd5f7346ff7d66b25a"
PREVIOUS_RUNNER = "3b4a73bc49f19d7440d2154bf31fe39266d781d1df8862dc99b21052d5b20a66"
PAIR = ("lf52-271a04aa", "wa30-ee6fef47")
GIB = 1024**3
FLAGS = ("candidate", "baseline")
GUARDS = {
    "memory_gib": 8,
    "disk_gib": 16,
    "cold_slots": 27,
    "case_cpu_count": 27,
    "slow_start_seconds": 60,
    "poll_seconds": 3,
    "startup_grace_seconds": 240,
}


def need(ok, msg):
    if not ok:
        raise RuntimeError(msg)


def read(path):
    return json.loads(path.read_bytes())


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, sort_keys=True, indent=2) + "\n")
    os.replace(tmp, path)


def file_sha(path):
    return sha256(path.read_bytes()).hexdigest()


def api_for(tree):
    sys.path[:0] = [str(tree), str(tree / "python/src")]
    os.chdir(tree)
    from scripts import evaluate_public25 as api
    import tddesc_tools.run as run
    import tddesc_tools.stitch as stitch

    from scripts import evaluate_public24 as evaluator
    from tests.bench import check_real_public as bench

    need(
        api.evaluate_game.__globals__["evaluate_isolated"]
        is evaluator.evaluate_isolated
        and evaluator.evaluate_isolated.__globals__["private_network"]
        is evaluator.private_network
        and evaluator.evaluate_one.__globals__["offline_capture"]
        is bench.offline_capture
        and bench.offline_capture.__globals__["environment_server"]
        is bench.environment_server,
        "Frozen public evaluator chain differs",
    )
    for mod in (api, run, stitch, evaluator, bench):
        need(
            Path(mod.__file__).resolve().is_relative_to(tree),
            "Imported module outside checkout",
        )
    need(api.ROOT.resolve() == tree, "Evaluation root differs")
    for name in ("prepare_cases", "evaluate_game", "game_verdict", "campaign_report"):
        need(callable(getattr(api, name)), name)
    return api


def check_bundle(bundle):
    need(file_sha(ARCHIVE) == ARCHIVE_SHA, "Frozen payload archive checksum differs")
    catalog = bundle / "offline_public_games_manifest.json"
    need(file_sha(catalog) == CATALOG_SHA, "Frozen catalog differs")
    inventory = {}
    with tarfile.open(ARCHIVE, "r:gz") as tar:
        for m in tar.getmembers():
            if m.isdir():
                continue
            name = m.name.removeprefix("./")
            need(
                m.isfile()
                and not name.startswith("/")
                and ".." not in Path(name).parts
                and name not in inventory,
                "Unexpected archive member",
            )
            inventory[name] = sha256(tar.extractfile(m).read()).hexdigest()
    installed = {
        p.relative_to(bundle).as_posix(): file_sha(p)
        for p in (bundle / "environment_files").rglob("*")
        if p.is_file()
    }
    installed[catalog.name] = file_sha(catalog)
    need(
        len(installed) == 51 and inventory == installed,
        "Installed environment differs from the pinned 50 payload files and catalog",
    )
    return sha256(
        json.dumps(sorted(installed.items()), separators=(",", ":")).encode()
    ).hexdigest()


def checked(arm, rev, bundle):
    need(arm in FLAGS and re.fullmatch(r"[0-9a-f]{40}", rev), "Expected exact commit")
    tree = (CHECKOUTS / f"TddESCat-v13-{arm}-{rev[:8]}").resolve(strict=True)

    def git(*args):
        return subprocess.check_output(["git", "-C", tree, *args], text=True).strip()

    need(
        git("rev-parse", "HEAD") == rev and not git("status", "--porcelain"),
        "Checkout differs or is dirty",
    )
    api = api_for(tree)
    template = tree / "config/v13_public25.toml"
    data = tomllib.loads(template.read_text())
    need(
        file_sha(template) == PROFILE_SHA
        and data["execution"]["max_public_commands"] == "unlimited",
        "Wrong profile",
    )
    suite = api.read_task(tree / "config/acceptance/arc_public25.toml")
    games = list(suite["game_ids"]) if arm == "candidate" else list(PAIR)
    catalog = read(bundle / "offline_public_games_manifest.json")
    need(
        len(set(suite["game_ids"])) == len(suite["game_ids"]) == 25
        and sorted(g.split("-")[0] for g in suite["game_ids"])
        == sorted(catalog["available_games"])
        and all(g in suite["game_ids"] for g in games),
        "Invalid game list",
    )
    for g in suite["game_ids"]:
        prefix, version = g.split("-")
        need(
            (
                bundle / "environment_files" / prefix / version / "metadata.json"
            ).is_file(),
            f"Missing {g}",
        )
    model = (template.parent / data["learning"]["engine"]).resolve()
    policy = (template.parent / data["learning"]["policy_file"]).resolve()
    factor = (template.parent / data["compute"]["factor_kernel"]).resolve()
    pin = dict(
        arm=arm,
        commit=rev,
        root=str(tree),
        game_ids=games,
        command_budget="unlimited",
        precompile_online=True,
        bundle=str(bundle),
        bundle_archive_sha256=ARCHIVE_SHA,
        catalog_sha256=CATALOG_SHA,
        bundle_tree_sha256=check_bundle(bundle),
        profile_sha256=PROFILE_SHA,
        suite_sha256=file_sha(tree / "config/acceptance/arc_public25.toml"),
        policy_sha256=file_sha(policy),
        engine_sha256=file_sha(model),
        factor_kernel_sha256=file_sha(factor),
    )
    return tree, api, template, suite, pin


def child_command(arm, rev, bundle, output, mode, game=None):
    tree = CHECKOUTS / f"TddESCat-v13-{arm}-{rev[:8]}"
    cmd = [
        str(tree / ".venv/bin/python"),
        "-u",
        str(HERE),
        mode,
        arm,
        rev,
        str(bundle),
        str(output),
    ]
    return cmd + ([game] if game else [])


def launch_slots(campaign):
    locks = campaign / "sdk-slots"
    locks.mkdir(exist_ok=True)
    for index in range(GUARDS["cold_slots"]):
        (locks / f"slot-{index}").touch(exist_ok=True)
    if not (locks / "policy.json").exists():
        write(locks / "policy.json", {"capacity": GUARDS["cold_slots"]})


def cpu_assignment(pins, cpus):
    games = [(arm, game) for arm in FLAGS for game in pins[arm]["game_ids"]]
    # Leave the lowest available IDs to the OS and driver. Order is the suite's
    # fixed list, identical for all games. Each baseline also has its own core.
    need(
        len(games) == GUARDS["case_cpu_count"],
        "Expected all 25 candidate and 2 baseline cases",
    )
    cpus = sorted(cpus)
    need(
        len(cpus) >= len(games),
        f"{len(games)} dedicated game CPUs required, saw {len(cpus)}",
    )
    return {
        f"{arm}/{game}": cpu
        for (arm, game), cpu in zip(games, cpus[-len(games) :], strict=True)
    }


class CaseSystemdProcesses:
    # Scope processes inherit affinity today. Service processes are forked by
    # systemd's user manager. Put taskset at the exec boundary of both types.
    def __init__(self, cpu):
        self.cpu = cpu

    def __getattr__(self, name):
        return getattr(subprocess, name)

    def Popen(self, command, *args, **kwargs):
        if (
            isinstance(command, (list, tuple))
            and command
            and Path(command[0]).name == "systemd-run"
            and "--" in command
        ):
            split = command.index("--") + 1
            command = [
                *command[:split],
                "/usr/bin/taskset",
                "--cpu-list",
                str(self.cpu),
                *command[split:],
            ]
        return subprocess.Popen(command, *args, **kwargs)


def process_masks(root):
    # Inspect already-running descendants and never delay or pause the SDK.
    rows = []
    todo = [root]
    while todo:
        pid = todo.pop()
        task = Path(f"/proc/{pid}")
        try:
            children = (task / "task" / str(pid) / "children").read_text().split()
            rows.append(
                dict(
                    pid=pid,
                    comm=(task / "comm").read_text().strip(),
                    cpus=sorted(os.sched_getaffinity(pid)),
                )
            )
            todo.extend(map(int, children))
        except (ProcessLookupError, FileNotFoundError, PermissionError):
            continue
    return rows


def isolated_game(tree, case, campaign):
    # This process is already inside exactly the production evaluator's outer bwrap.
    # The solver and SDK still use their own ordinary inner sandboxes.
    from contextlib import ExitStack

    api_for(tree)
    import scripts.evaluate_public24 as evaluator
    import tests.bench.check_real_public as bench

    from tddesc_tools import public_run, stitch

    allowed = sorted(os.sched_getaffinity(0))
    need(len(allowed) == 1, "Evaluator must have its dedicated CPU")
    cpu = allowed[0]
    resources = CaseSystemdProcesses(cpu)
    public_run.subprocess = resources
    stitch.subprocess = resources
    original = bench.environment_server

    @contextmanager
    def admitted(*args, **kwargs):
        name = Path(args[4]).name
        record = case / "grade" / f"sdk-admission-{name}.json"
        waiting = time.time()
        write(record, {"state": "WAITING", "since": waiting})
        locks = campaign / "sdk-slots"
        initial = name == "server" and case.name != "transport-retry"
        slot = None
        while not initial and slot is None:
            capacity = read(locks / "policy.json")["capacity"]
            for n in range(capacity):
                candidate = (locks / f"slot-{n}").open("rb")
                try:
                    fcntl.flock(candidate, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    candidate.close()
                    continue
                slot = candidate
                break
            if slot is None:
                time.sleep(1)
        started = time.time()
        metadata = {
            "slot": "dedicated_initial" if initial else slot.name,
            "assigned_cpu": cpu,
            "first_sdk_for_case": initial,
            "admitted": started,
            "wait_seconds": started - waiting,
            "timeout": kwargs.get("startup_timeout"),
        }
        # ExitStack owns the live SDK beyond admission. Its teardown and exceptions
        # are the original context manager's, including shutdown on solver failure.
        with ExitStack() as stack:
            try:
                write(record, dict(metadata, state="STARTING"))
                endpoint = stack.enter_context(original(*args, **kwargs))
                write(
                    record,
                    dict(
                        metadata,
                        state="READY",
                        startup_seconds=time.time() - started,
                        ready_at=time.time(),
                        live_cpu_masks=process_masks(endpoint[1]),
                    ),
                )
            except Exception as exc:
                write(
                    record,
                    dict(
                        metadata,
                        state="FAILED",
                        startup_seconds=time.time() - started,
                        error=str(exc),
                    ),
                )
                raise
            finally:
                if slot is not None:
                    slot.close()
            yield endpoint

    bench.environment_server = admitted
    try:
        return int(not evaluator.evaluate_one(case).get("verified", False))
    finally:
        bench.environment_server = original


def with_admission(api, tree, campaign, case, game, runtime):
    # Keep the frozen evaluate_isolated implementation. Its single --one
    # entry point is decorated with the shared startup admission context.
    import scripts.evaluate_public24 as evaluator

    original = evaluator.private_network

    def gated(command, writable):
        need(
            len(command) == 5
            and list(command[1:4]) == ["-m", "scripts.evaluate_public24", "--one"]
            and Path(command[4]) in (case, case / "transport-retry"),
            "Unexpected native evaluator command",
        )
        return original(
            [
                command[0],
                "-u",
                str(HERE),
                "_isolated",
                str(tree),
                command[4],
                str(campaign),
            ],
            writable,
        )

    evaluator.private_network = gated
    try:
        return api.evaluate_game(case, game, runtime)
    finally:
        evaluator.private_network = original


def retained_baseline(source, stage, pin, identity, runtime):
    # Only immutable qualification/configuration records are read. Fresh
    # per-game settings were just generated independently by prepare_cases.
    source = Path(source).resolve(strict=True)
    need(
        source.name == "manifest.json" and source.parent.name == "baseline",
        "Expected baseline manifest",
    )
    old_plan = read(source.parents[1] / "plan.json")
    snapshot = source.parents[1] / "runner" / PREVIOUS_RUNNER / "fair-public25.py"
    old = read(source)
    need(
        pin["arm"] == "baseline" and old_plan["arms"]["baseline"] == pin,
        "Baseline pin differs",
    )
    need(
        old_plan["runner_sha256"]
        == old["runner_sha256"]
        == file_sha(snapshot)
        == PREVIOUS_RUNNER
        and Path(old_plan["runner_path"]).resolve(strict=True) == snapshot,
        "Qualification runner differs",
    )
    for key, value in {**pin, **identity}.items():
        need(old.get(key) == value, "Baseline qualification differs: " + key)
    for game in pin["game_ids"]:
        for filename in ("agent.toml", "task.toml"):
            need(
                (stage / game / filename).read_bytes()
                == (source.parent / game / filename).read_bytes(),
                "Per-game settings differ",
            )
    tree = Path(pin["root"])
    cap = old["compute"]
    required = {"circuit_python", "factor_kernel", "policy_synthesis", "solver_python"}
    need(
        set(cap["capabilities"]) == required
        and all(row.get("operations") for row in cap["capabilities"].values())
        and cap["factor_kernel_sha256"] == pin["factor_kernel_sha256"]
        and cap["compute_lock_sha256"] == file_sha(tree / "python/compute/uv.lock"),
        "Compute qualification differs",
    )
    online = old["online_runtime"]
    need(
        online["enabled"] is True
        and online["compiled"] is True
        and online["julia_version"] == runtime["julia"]["version"],
        "Online runtime differs",
    )
    saved_at = source.stat().st_mtime_ns
    config = tomllib.loads((stage / pin["game_ids"][0] / "agent.toml").read_text())
    files = [
        tree / "config/runtime.local.toml",
        tree / "julia/TddESCat/LocalPreferences.toml",
        Path(runtime["julia"]["executable"]),
        Path(runtime["python"]["executable"]),
        *(Path(config["compute"][key]) for key in ("solver_python", "circuit_python")),
    ]
    need(
        all(
            file.resolve(strict=True).stat().st_mtime_ns < saved_at
            and file.lstat().st_mtime_ns < saved_at
            for file in files
        ),
        "Runtime changed since original qualification",
    )
    return (
        online,
        cap,
        dict(
            mode="retained_baseline_qualification",
            source_manifest=str(source),
            source_manifest_sha256=file_sha(source),
            source_manifest_mtime_ns=saved_at,
            source_plan_sha256=file_sha(source.parents[1] / "plan.json"),
            source_runner_sha256=PREVIOUS_RUNNER,
            source_commit=old["commit"],
        ),
    )


def arm_command(mode, arm, rev, bundle_name, output_name, game=None):
    bundle = Path(bundle_name).resolve(strict=True)
    output = Path(output_name).resolve()
    tree, api, template, suite, pin = checked(arm, rev, bundle)
    if mode == "_dry":
        print(json.dumps(pin, sort_keys=True))
        return
    runtime = api.runtime_paths(tree)
    path = output / arm
    if mode == "_prepare":
        lock = (output / f".prepare-{arm}.lock").open("a")
        fcntl.flock(lock, fcntl.LOCK_EX)
        if (path / "manifest.json").exists():
            old = read(path / "manifest.json")
            need(
                all(old[k] == v for k, v in pin.items()),
                "Prepared campaign pin differs",
            )
            return
        # A partial preparation can be repeated before dispatch. prepare_cases uses
        # exclusive case directories, so stage the entire arm and then rename it.
        import tempfile

        stage = Path(tempfile.mkdtemp(prefix=f".preparing-{arm}-", dir=output))
        # The precompile artifacts are installed by the operator. The preference
        # is atomically switched last so an active stock preflight is undisturbed.
        local_prefs = tree / "julia/TddESCat/LocalPreferences.toml"
        print(f"{arm}: waiting for native online-method cache installation", flush=True)
        while not (
            local_prefs.is_file()
            and tomllib.loads(local_prefs.read_text())
            .get("TddESCat", {})
            .get("precompile_online")
            is True
        ):
            time.sleep(GUARDS["poll_seconds"])
        engine, policy = api.prepare_cases(
            stage, tuple(pin["game_ids"]), template, suite, bundle
        )
        identity = dict(
            worktree_sha256=api.worktree_digest(tree),
            solver_source_sha256=api.worktree_digest(tree, sources_only=True),
            engine=api.build_identity(tree, engine),
        )
        qualification = {"mode": "native"}
        source = (
            read(output / "plan.json").get("baseline_qualification")
            if arm == "baseline"
            else None
        )
        retained = None
        if source:
            try:
                retained = retained_baseline(source, stage, pin, identity, runtime)
            except (OSError, KeyError, TypeError, ValueError, RuntimeError) as exc:
                qualification.update(fallback_source=source, fallback_reason=str(exc))
                print(f"{arm}: using native qualification ({exc})", flush=True)
        if retained:
            online, cap, qualification = retained
        else:
            online = api.prepare_online_runtime(runtime)
            need(
                online.get("enabled") is True and online.get("compiled") is True,
                "Native online precompile failed",
            )
            cap = api.verify_compute_profile(template, runtime)
        manifest = dict(
            pin,
            **identity,
            schema_version=1,
            qualified_at=time.time(),
            qualification=qualification,
            compute=cap,
            online_runtime=online,
            workers=len(pin["game_ids"]),
            runner_guards=GUARDS,
            runner_sha256=file_sha(HERE),
        )
        api.atomic_json(stage / "manifest.json", manifest)
        api.atomic_json(
            stage / "public25.json", api.campaign_report(pin["game_ids"], {})
        )
        stage.rename(path)
        return
    manifest = read(path / "manifest.json")
    need(
        all(manifest[k] == v for k, v in pin.items())
        and manifest["runner_sha256"] == file_sha(HERE),
        "Worker pin differs",
    )
    need(game in pin["game_ids"], "Game outside arm scope")
    case = path / game
    expected_cpu = read(output / "plan.json")["cpu_assignment"][f"{arm}/{game}"]
    allowed = sorted(os.sched_getaffinity(0))
    need(allowed == [expected_cpu], f"Wrong case CPU for {arm}/{game}: {allowed}")
    with (case / "grade/runner-started.json").open("x") as started:
        json.dump(
            dict(
                commit=rev,
                pid=os.getpid(),
                started=time.time(),
                assigned_cpu=expected_cpu,
                cpus_allowed=allowed,
                runner_sha256=file_sha(HERE),
            ),
            started,
        )
    try:
        row = with_admission(api, tree, output, case, game, runtime)
        need(row["game_id"] == game, "Result ID differs")
    except Exception as exc:
        row = dict(
            game_id=game,
            verified=False,
            worker_exit=1,
            error=f"{type(exc).__name__}: {exc}",
        )
    row["verdict"] = api.game_verdict(row)
    api.atomic_json(case / "grade/runner-result.json", row)
    print(json.dumps(dict(game=game, verdict=row["verdict"])), flush=True)


def room(output):
    mem = {
        k: int(v.split()[0]) * 1024
        for k, v in (
            r.split(":", 1) for r in Path("/proc/meminfo").read_text().splitlines()
        )
    }
    return dict(
        memory_available_gib=round(mem["MemAvailable"] / GIB, 2),
        disk_available_gib=round(shutil.disk_usage(output).free / GIB, 2),
        vcpus=len(os.sched_getaffinity(0)),
        load1=os.getloadavg()[0],
    )


def observed_start(case, info):
    attempt = case / "transport-retry" if (case / "transport-retry").is_dir() else case
    public = attempt / "public"
    stage = "retry" if attempt != case else "original"
    if info.get("attempt") != stage:
        info.update(attempt=stage, latest_sequence=0)
    if not info.get("first_reset", {}).get(stage):
        # The public interface opens a scorecard, then dispatches RESET. Its
        # immutable event mtime records when the confirmed initial frame landed.
        cmd = public / "commands/c000000002.json"
        if cmd.exists():
            reset = read(cmd)
            if reset["kind"] == "reset" and reset["completion"] == "confirmed":
                event = public / "events" / (reset["event_id"] + ".json")
                response = public / "blobs" / reset["response_blob"]
                payload = response.read_bytes()
                need(
                    sha256(payload).hexdigest() == reset["response_blob"],
                    "RESET digest differs",
                )
                from scripts.evaluate_public24 import frame_identity

                observation = json.loads(payload)
                info.setdefault("first_reset", {})[stage] = {
                    "confirmed_event_mtime_ns": event.stat().st_mtime_ns,
                    "recorded_at": time.time(),
                    "event": reset["event_id"],
                    "response_blob": reset["response_blob"],
                    "frame_sha256": frame_identity(observation),
                    "legal_actions": sorted(observation["available_actions"]),
                    "state": observation["state"],
                    "game_id": observation["game_id"],
                    "win_levels": observation["win_levels"],
                    "full_reset": observation.get("full_reset"),
                    "levels_completed": observation["levels_completed"],
                }
    # Sequence filenames are contiguous. Probe only the incremental range.
    cmd_dir = public / "commands"
    seq = info["latest_sequence"]

    def filename(n):
        return cmd_dir / f"c{n:09}.json"

    if filename(seq + 1).is_file():
        low = seq + 1
        high = low + 1
        while filename(high).is_file():
            high = low + 2 * (high - low)
        while high - low > 1:
            mid = (low + high) // 2
            if filename(mid).is_file():
                low = mid
            else:
                high = mid
        seq = info["latest_sequence"] = low
    latest = read(filename(seq)) if seq and filename(seq).is_file() else {}
    disposition = latest.get("completion")
    info["public_command"] = {
        "sequence": seq,
        "completion": disposition,
        "kind": latest.get("kind"),
        "transaction_unresolved": disposition
        in ("prepared", "sent", "outcome_unknown"),
        "inflight": True
        if disposition == "sent"
        else None
        if disposition in ("prepared", "outcome_unknown")
        else False,
    }
    for name in ("server-start-retry", "server"):
        p = attempt / "grade" / f"sdk-admission-{name}.json"
        if p.is_file():
            admission = read(p)
            info["sdk"] = admission
            if admission["state"] == "READY":
                return True
            if admission["state"] in ("WAITING", "STARTING"):
                return False
    return (
        (public / "solver-isolation.json").is_file()
        or disposition == "confirmed"
        or any(
            (attempt / "private" / n / "ready.json").exists()
            for n in ("server", "server-start-retry")
        )
    )


def start_preparations(args, plan):
    jobs = {}
    for arm, pin in plan["arms"].items():
        log_name = args.output / f"prepare-{arm}.log"
        command = child_command(
            arm, pin["commit"], args.bundle, args.output, "_prepare"
        )
        job = jobs[arm] = {
            "state": "PREPARING",
            "started": time.time(),
            "log": str(log_name),
        }
        try:
            with log_name.open("ab") as log:
                job["process"] = subprocess.Popen(
                    command, stdout=log, stderr=subprocess.STDOUT
                )
        except OSError as exc:
            job.update(state="FAILED", failed_at=time.time(), diagnostic=str(exc))
    return jobs


def preparation_states(output, plan, jobs):
    for arm, job in jobs.items():
        proc = job.get("process")
        code = proc.poll() if proc is not None else None
        if job["state"] != "PREPARING":
            continue
        path = output / arm / "manifest.json"
        if path.is_file():
            try:
                manifest = read(path)
                pin = plan["arms"][arm]
                need(
                    all(manifest.get(k) == v for k, v in pin.items())
                    and manifest.get("runner_sha256") == plan["runner_sha256"]
                    and manifest["online_runtime"].get("enabled") is True
                    and manifest["online_runtime"].get("compiled") is True
                    and bool(manifest["compute"]["capabilities"]),
                    f"Qualification mismatch for {arm}",
                )
                job.update(state="QUALIFIED", qualified_at=manifest["qualified_at"])
            except (OSError, KeyError, TypeError, ValueError, RuntimeError) as exc:
                job.update(state="FAILED", failed_at=time.time(), diagnostic=str(exc))
        elif code is not None:
            job.update(state="FAILED", failed_at=time.time(), exit_code=code)
    return {
        a: {k: v for k, v in job.items() if k != "process"} for a, job in jobs.items()
    }


def pair_starts(state):
    reports = {}
    for game in PAIR:
        starts = {}
        for arm in FLAGS:
            row = state["submitted"].get(f"{arm}/{game}", {})
            attempts = row.get("first_reset", {})
            starts[arm] = attempts.get(row.get("attempt", "original"))
        matched = None
        if all(starts.values()):
            identity = (
                "frame_sha256",
                "state",
                "game_id",
                "win_levels",
                "full_reset",
                "levels_completed",
                "legal_actions",
            )
            matched = all(
                starts["candidate"][k] == starts["baseline"][k] for k in identity
            )
        reports[game] = dict(starts=starts, same_public_start=matched)
    return reports


def schedule(args, plan, jobs):
    order = [(arm, game) for arm in FLAGS for game in plan["arms"][arm]["game_ids"]]
    need(len(set(order)) == len(order) == 27, "Expected exactly 27 independent cases")
    tag = sha256(str(args.output).encode()).hexdigest()[:12]
    casefile = args.output / "launcher.json"
    state = read(casefile) if casefile.exists() else dict(submitted={}, last_launch=0)
    api = api_for(Path(plan["arms"]["candidate"]["root"]))
    attempts = state.setdefault("attempts", {})
    while True:
        prep = preparation_states(args.output, plan, jobs)
        ready = {a for a in FLAGS if prep[a]["state"] == "QUALIFIED"}
        preparing = {a for a in FLAGS if prep[a]["state"] == "PREPARING"}
        failed = {a for a in FLAGS if prep[a]["state"] == "FAILED"}
        state["preparations"] = prep
        results = {a: {} for a in FLAGS}
        for a, g in order:
            result = args.output / a / g / "grade/runner-result.json"
            if result.exists():
                results[a][g] = read(result)
        # If the coordinator was interrupted after recording an intent, reconcile
        # the service before considering another submission of that case.
        if time.time() - state.get("last_reconciliation", 0) >= 120:
            watched = subprocess.check_output(
                [
                    "systemctl",
                    "--user",
                    "list-units",
                    f"pub25-{tag}-*.service",
                    "--all",
                    "--no-legend",
                    "--plain",
                    "--no-pager",
                ],
                text=True,
            )
            active = {
                fields[0]
                for line in watched.splitlines()
                if len(fields := line.split()) >= 4
                and fields[2] not in ("failed", "inactive")
            }
            for key, info in list(state["submitted"].items()):
                a, g = key.split("/")
                if (
                    g in results[a]
                    or time.time() - info["time"] < GUARDS["startup_grace_seconds"]
                    or info["unit"] + ".service" in active
                ):
                    continue
                case = args.output / a / g
                if (
                    not (case / "grade/runner-started.json").exists()
                    and not (case / "public/commands").exists()
                ):
                    del state["submitted"][key]
                    continue
                # A missing process after its durable start may have transmitted a
                # request. Keep its full public ledger and never redispatch its GUID.
                row = {
                    "game_id": g,
                    "verified": False,
                    "worker_exit": 1,
                    "error": "Detached evaluator exited without a final row",
                }
                row["verdict"] = api.game_verdict(row)
                api.atomic_json(case / "grade/runner-result.json", row)
                results[a][g] = row
            state["last_reconciliation"] = time.time()
        for a in ready:
            api.atomic_json(
                args.output / a / "public25.json",
                api.campaign_report(plan["arms"][a]["game_ids"], results[a]),
            )
        pending = [
            (a, g)
            for a, g in order
            if a in ready
            and g not in results[a]
            and f"{a}/{g}" not in state["submitted"]
        ]
        living = len(state["submitted"]) - sum(len(s) for s in results.values())
        state.update(
            resources=room(args.output),
            queued=len(pending),
            awaiting_qualification=sum(
                len(plan["arms"][a]["game_ids"]) for a in preparing
            ),
            qualification_blocked=sum(len(plan["arms"][a]["game_ids"]) for a in failed),
            unfinished_submissions=living,
            asof=time.time(),
        )
        waiting = []
        latest = []
        for key, info in state["submitted"].items():
            a, g = key.split("/")
            if info.get("finished"):
                continue
            admitted = observed_start(args.output / a / g, info)
            if g in results[a]:
                info["finished"] = True
                continue
            if not admitted:
                waiting.append(key)
            sample = info.get("sdk", {})
            if "startup_seconds" in sample:
                latest.append((sample["admitted"], sample["startup_seconds"]))
        recent = [seconds for _, seconds in sorted(latest)[-3:]]
        pressure = state["resources"]["memory_available_gib"] < 14
        timeout_receipts = [
            info["sdk"]
            for info in state["submitted"].values()
            if info.get("sdk", {}).get("state") == "FAILED"
            and info["sdk"].get("startup_seconds", 0) >= GUARDS["slow_start_seconds"]
        ]
        # The first start of each qualified game has its own dedicated slot.
        # This gate handles transport/server *retries* only, after real pressure.
        capacity = 2 if pressure or timeout_receipts else GUARDS["cold_slots"]
        gate = args.output / "sdk-slots" / "policy.json"
        if read(gate)["capacity"] != capacity:
            write(gate, {"capacity": capacity})
        state.update(
            initial_start_capacity=len(plan["cpu_assignment"]),
            retry_capacity=capacity,
            retry_throttled_by_confirmed_timeout=bool(timeout_receipts),
            awaiting_startup=waiting,
            recent_start_seconds=recent,
        )
        if not pending:
            if preparing:
                state["status"] = "WAIT_OTHER_ARM" if ready else "PREPARING"
            elif living:
                state["status"] = "ALL_QUALIFIED_CASES_DISPATCHED"
            else:
                state["status"] = (
                    "CLOSED_WITH_QUALIFICATION_FAILURE" if failed else "CLOSED"
                )
        elif (
            state["resources"]["memory_available_gib"] < GUARDS["memory_gib"]
            or state["resources"]["disk_available_gib"] < GUARDS["disk_gib"]
        ):
            state["status"] = "WAIT_RESOURCES"
        else:
            state["status"] = "DISPATCH_QUALIFIED_CASES"
            a, g = min(pending, key=lambda job: attempts.get("/".join(job), 0))
            key = f"{a}/{g}"
            attempts[key] = attempts.get(key, 0) + 1
            unit = f"pub25-{tag}-{a}-{g.split('-')[0]}"
            case = args.output / a / g
            need(
                not (case / "grade/runner-started.json").exists()
                and not (case / "public/commands").exists(),
                f"Unowned prior case {case}: reconcile its existing process",
            )
            rev = plan["arms"][a]["commit"]
            cpu = plan["cpu_assignment"][key]
            command = [
                "/usr/bin/taskset",
                "--cpu-list",
                str(cpu),
                *child_command(a, rev, args.bundle, args.output, "_game", g),
            ]
            info = dict(unit=unit, time=time.time(), command=command, assigned_cpu=cpu)
            # A stable unit ID fences concurrent submissions. Persist the intent before starting.
            info["state"] = "SUBMITTING"
            state["submitted"][f"{a}/{g}"] = info
            state["last_launch"] = info["time"]
            write(casefile, state)
            proc = subprocess.run(
                [
                    "systemd-run",
                    "--user",
                    "--collect",
                    f"--unit={unit}",
                    f"--property=CPUAffinity={cpu}",
                    "--service-type=exec",
                    f"--property=WorkingDirectory={plan['arms'][a]['root']}",
                    f"--property=StandardOutput=append:{case}/grade/runner.log",
                    f"--property=StandardError=append:{case}/grade/runner.log",
                    "--",
                    *command,
                ],
                capture_output=True,
                text=True,
            )
            info.update(
                state="ACCEPTED" if not proc.returncode else "LAUNCH_FAILED",
                diagnostic=(proc.stdout + proc.stderr).strip(),
            )
            if proc.returncode:
                # No retry of a possibly running command. A fresh other case remains independent.
                write(casefile, state)
                print(info["diagnostic"], flush=True)
        state["pair_starts"] = pair_starts(state)
        write(casefile, state)
        if not living and not pending and not preparing:
            return int(bool(failed))
        if not (len(pending) > 1 and state["status"] == "DISPATCH_QUALIFIED_CASES"):
            time.sleep(GUARDS["poll_seconds"])


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "_isolated":
        raise SystemExit(isolated_game(*(Path(a) for a in sys.argv[2:])))
    if len(sys.argv) > 1 and sys.argv[1] in ("_dry", "_prepare", "_game"):
        arm_command(*sys.argv[1:])
        return
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("mode", choices=("dry", "run"))
    p.add_argument("--candidate", required=True)
    p.add_argument("--baseline", required=True)
    p.add_argument(
        "--baseline-qualification",
        type=Path,
        help="Optional prior manifest for the identical baseline checkout",
    )
    p.add_argument("--bundle", type=Path, default=DEFAULT_BUNDLE)
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    args.bundle = args.bundle.resolve(strict=True)
    args.output = args.output.resolve()
    for rev in (args.candidate, args.baseline):
        need(re.fullmatch(r"[0-9a-f]{40}", rev), "Both commits must be complete SHAs")
    pins = {}
    for a in FLAGS:
        pins[a] = json.loads(
            subprocess.check_output(
                child_command(a, getattr(args, a), args.bundle, args.output, "_dry"),
                text=True,
            )
        )
    for k in (
        "bundle_tree_sha256",
        "profile_sha256",
        "suite_sha256",
        "policy_sha256",
        "engine_sha256",
        "factor_kernel_sha256",
    ):
        need(
            pins["candidate"][k] == pins["baseline"][k], "Paired setting differs: " + k
        )
    pin_sha = file_sha(HERE)
    snapshot = args.output / "runner" / pin_sha / HERE.name
    plan = dict(
        arms=pins,
        cpu_assignment=cpu_assignment(pins, os.sched_getaffinity(0)),
        cpu_assignment_policy="one distinct guest CPU per case in frozen manifest order",
        guards=GUARDS,
        reused_candidate_pairs=list(PAIR),
        baseline_qualification=str(args.baseline_qualification.resolve())
        if args.baseline_qualification
        else None,
        runner_sha256=pin_sha,
        runner_path=str(snapshot),
    )
    if args.mode == "dry":
        print(
            json.dumps(
                dict(
                    plan=plan,
                    case_count=27,
                    resources=room(args.output.parent),
                    sdk_starts=0,
                    worker_commands=[
                        [
                            "/usr/bin/taskset",
                            "--cpu-list",
                            str(plan["cpu_assignment"][f"{a}/{g}"]),
                            *child_command(
                                a,
                                getattr(args, a),
                                args.bundle,
                                args.output,
                                "_game",
                                g,
                            ),
                        ]
                        for a in FLAGS
                        for g in pins[a]["game_ids"]
                    ],
                    private_worker_entry="_isolated inside native evaluate_isolated/private_network",
                    systemd_run=shutil.which("systemd-run"),
                ),
                sort_keys=True,
            )
        )
        return
    args.output.mkdir(parents=True, exist_ok=True)
    lock = (args.output / ".launcher.lock").open("a")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if (args.output / "plan.json").exists():
        need(read(args.output / "plan.json") == plan, "Run identity differs")
    else:
        need(
            not any(p.name != ".launcher.lock" for p in args.output.iterdir()),
            "Run directory must initially be empty",
        )
        write(args.output / "plan.json", plan)
    snapshot.parent.mkdir(parents=True, exist_ok=True)
    if not snapshot.exists():
        temporary = snapshot.with_suffix(".incoming")
        shutil.copyfile(HERE, temporary)
        os.replace(temporary, snapshot)
    need(file_sha(snapshot) == pin_sha, "Archived runner checksum differs")
    if HERE != snapshot:
        os.execv(sys.executable, [sys.executable, "-u", str(snapshot), *sys.argv[1:]])
    launch_slots(args.output)
    jobs = start_preparations(args, plan)
    raise SystemExit(schedule(args, plan, jobs))


if __name__ == "__main__":
    main()
