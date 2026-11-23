"""Install the locked project environments and run their dependency smoke tests."""

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def resolve_tool(name: str, explicit: Path | None = None) -> Path:
    path = shutil.which(str(explicit) if explicit else name)
    if path is None:
        raise SystemExit(f"Executable not found: {explicit or name}")
    return Path(os.path.abspath(path))


def check_version(tool: Path, expected: str, name: str) -> None:
    actual = subprocess.check_output([tool, "--version"], cwd=ROOT, text=True).strip()
    if actual.split()[:2] != [name, expected]:
        raise SystemExit(f"Expected {name} {expected}, got {actual!r} from {tool}")
    print(f"{actual} — {tool}", flush=True)


def main() -> None:
    if sys.version_info < (3, 11):
        uv = resolve_tool("uv")
        os.execv(
            uv,
            [
                str(uv),
                "run",
                "--no-project",
                "--python",
                ">=3.11",
                "--",
                "python",
                *sys.argv,
            ],
        )

    import tomllib

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument(
        "--julia", type=Path, help="Path to the pinned Julia executable"
    )
    args = parser.parse_args()
    with args.config.open("rb") as source:
        config = tomllib.load(source)

    python_version = config["python"]["version"]
    julia_version = config["julia"]["version"]
    rust_version = config["rust"]["version"]
    uv = resolve_tool("uv")
    candidate = ROOT / ".runtime" / f"julia-{julia_version}" / "bin" / "julia"
    julia = resolve_tool(
        "julia", args.julia or (candidate if candidate.is_file() else None)
    )
    cargo = resolve_tool("cargo")
    rustc = resolve_tool("rustc")
    actual_julia = subprocess.check_output(
        [julia, "--version"], cwd=ROOT, text=True
    ).strip()
    if actual_julia != f"julia version {julia_version}":
        raise SystemExit(
            f"Expected Julia {julia_version}, got {actual_julia!r} from {julia}"
        )
    print(f"{actual_julia} — {julia}", flush=True)
    check_version(cargo, rust_version, "cargo")
    check_version(rustc, rust_version, "rustc")

    python = ROOT / ".venv" / "bin" / "python"
    uv_env = dict(os.environ, UV_PROJECT_ENVIRONMENT=str(python.parent.parent))
    uv_env.pop("VIRTUAL_ENV", None)
    subprocess.run(
        [
            uv,
            "sync",
            "--project",
            "python",
            "--python",
            python_version,
            "--locked",
        ],
        cwd=ROOT,
        env=uv_env,
        check=True,
    )
    check_version(python, python_version, "Python")
    subprocess.run(
        [python, "scripts/check_sources.py", "--config", "config/sources.lock.toml"],
        cwd=ROOT,
        check=True,
    )
    subprocess.run([python, "tests/python/dependency_smoke.py"], cwd=ROOT, check=True)
    subprocess.run([python, "-m", "tddesc_tools.contracts"], cwd=ROOT, check=True)

    runtime = ROOT / "config" / "runtime.local.toml"
    depot = ROOT / ".runtime" / "julia-depot"
    runtime.write_text(
        "".join(
            f"[{key}]\nexecutable = {json.dumps(str(executable), ensure_ascii=False)}\n"
            f"version = {json.dumps(version)}\n\n"
            for key, executable, version in (
                ("python", python, python_version),
                ("julia", julia, julia_version),
                ("cargo", cargo, rust_version),
                ("rustc", rustc, rust_version),
            )
        )
        + f"[julia_cache]\ndepot = {json.dumps(str(depot), ensure_ascii=False)}\n",
        encoding="utf-8",
    )
    # Put project downloads and compilation outputs in the local cache.
    home_depot = Path.home() / ".julia"
    julia_env = dict(
        os.environ,
        JULIA_LOAD_PATH="@:@stdlib",
        JULIA_DEPOT_PATH=os.pathsep.join([str(depot), str(home_depot), ""]),
    )
    julia_command = [julia, "--startup-file=no", "--project=julia/TddESCat"]
    subprocess.run(
        [*julia_command, "-e", "using Pkg; Pkg.instantiate(; update_registry=false)"],
        cwd=ROOT,
        env=julia_env,
        check=True,
    )
    subprocess.run(
        [*julia_command, "scripts/preflight_julia.jl", "--config", runtime],
        cwd=ROOT,
        env=julia_env,
        check=True,
    )
    subprocess.run(
        [python, "scripts/check_toolchain.py", "--config", runtime],
        cwd=ROOT,
        check=True,
    )


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
