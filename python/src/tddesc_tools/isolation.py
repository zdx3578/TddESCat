"""Linux namespaces for the local, public-only acceptance workers."""

import json
import os
import shutil
import subprocess
from contextlib import contextmanager
from pathlib import Path
from time import monotonic, sleep

from .run import clean_environment


def bubblewrap():
    executable = shutil.which("bwrap")
    if executable is None:
        raise RuntimeError("Linux namespace verification requires bubblewrap")
    return executable


def private_network(command, writable):
    prefix = [
        bubblewrap(),
        "--die-with-parent",
        "--unshare-net",
        "--ro-bind",
        "/",
        "/",
        "--dev",
        "/dev",
        "--proc",
        "/proc",
        "--tmpfs",
        "/tmp",
    ]
    for directory in writable:
        prefix += ["--bind", str(directory), str(directory)]
    return [*prefix, "--", *command]


def sandbox(command, *, read=(), write=(), variables=None, offline=False):
    prefix = [
        bubblewrap(),
        "--die-with-parent",
        "--unshare-pid",
        "--unshare-ipc",
        "--unshare-uts",
        "--clearenv",
        "--dev",
        "/dev",
        "--proc",
        "/proc",
        "--tmpfs",
        "/tmp",
        "--ro-bind",
        "/usr",
        "/usr",
    ]
    if offline:
        prefix += ["--unshare-net"]
    for path in map(Path, ("/bin", "/sbin", "/lib", "/lib64", "/etc/ld.so.cache")):
        if path.is_symlink():
            prefix += ["--symlink", os.readlink(path), str(path)]
        elif path.exists():
            prefix += ["--ro-bind", str(path), str(path)]
    for flag, paths in (("--ro-bind", read), ("--bind", write)):
        for path in paths:
            prefix += [flag, str(path), str(path)]
    settings = {**clean_environment(), "HOME": "/tmp", **(variables or {})}
    for key, value in settings.items():
        prefix += ["--setenv", key, str(value)]
    return [*prefix, "--chdir", "/tmp", "--", *command]


def solver_sandbox(
    root, runtime, command, public, *, script, extra_read=(), offline=False
):
    julia = Path(runtime["julia"]["executable"]).resolve().parents[1]
    cache = Path(runtime["julia_cache"]["depot"])
    global_depot = Path.home() / ".julia"
    installed = tuple(
        path
        for name in ("packages", "artifacts", "compiled")
        if (path := global_depot / name).is_dir()
    )
    return sandbox(
        command,
        read=(julia, root / "julia/TddESCat", script, cache, *installed, *extra_read),
        write=(public,),
        variables={
            "JULIA_LOAD_PATH": "@:@stdlib",
            "JULIA_DEPOT_PATH": f"/tmp/julia:{cache}:{global_depot}:",
        },
        offline=offline,
    )


@contextmanager
def environment_server(root, runtime, server_config, games, work, log):
    python = Path(runtime["python"]["executable"])
    python_distribution = python.resolve().parents[1]
    work.mkdir(parents=True)
    cmd = sandbox(
        [
            str(python),
            "-m",
            "tddesc_env.serve",
            "--config",
            str(server_config),
            "--games",
            str(games),
            "--work",
            str(work),
        ],
        read=(
            python.parent.parent,
            python_distribution,
            root / "python/src/tddesc_env",
            server_config,
            games,
        ),
        write=(work,),
    )
    with log.open("wb") as output:
        server = subprocess.Popen(cmd, cwd=root, stdout=output, stderr=output)
        try:
            deadline = monotonic() + 20
            ready = work / "ready.json"
            while not ready.exists():
                if server.poll() is not None or monotonic() >= deadline:
                    raise RuntimeError(
                        f"Official HTTP server failed to start; see {log}"
                    )
                sleep(0.05)
            port = json.loads(ready.read_bytes())["port"]
            yield f"http://127.0.0.1:{port}", server.pid
        finally:
            server.terminate()
            try:
                server.wait(5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


def isolation_probe(root, url, game_data, private_path, server_pid, *, launch=sandbox):
    script = r"""
import importlib.util, json, os, socket, sys, urllib.error, urllib.request
url, game_data, private_path, server_pid, repo = sys.argv[1:]
checks = {
    "no_environment_import": importlib.util.find_spec("tddesc_env") is None,
    "no_private_game": not os.path.exists(game_data),
    "no_private_output": not os.path.exists(private_path),
    "no_repository": not os.path.exists(repo + "/.git"),
    "no_host_socket": not os.path.exists("/var/run/docker.sock"),
    "no_host_environment_pid": not os.path.exists("/proc/" + server_pid + "/cmdline")
}
procs = []
for item in os.listdir("/proc"):
    if item.isdecimal():
        try:
            with open(f"/proc/{item}/cmdline","rb") as process:
                procs.append(process.read())
        except OSError:
            pass
checks["no_environment_process"] = not any(
    b"tddesc_env.serve" in cmd.split(b"\x00") for cmd in procs
)
with urllib.request.urlopen(url + "/api/games", timeout=3) as response:
    checks["game_list_accessible"] = response.status == 200
for route in ("/oracle", "/debug", "/state", "/collision"):
    try:
        urllib.request.urlopen(url + route, timeout=3)
        checks[route] = False
    except urllib.error.HTTPError as error:
        checks[route] = error.code == 404
with socket.socket() as connection:
    connection.settimeout(0.5)
    try:
        checks["no_external_network"] = connection.connect_ex(("192.0.2.1", 80)) != 0
    except OSError:
        checks["no_external_network"] = True
print(json.dumps(checks))
sys.exit(not all(checks.values()))
"""
    result = subprocess.run(
        launch(
            [
                "/usr/bin/python3",
                "-I",
                "-c",
                script,
                url,
                str(game_data),
                str(private_path),
                str(server_pid),
                str(root),
            ]
        ),
        capture_output=True,
        text=True,
        timeout=15,
    )
    if result.returncode:
        raise RuntimeError(f"Isolation probe failed: {result.stdout}{result.stderr}")
    return json.loads(result.stdout)
