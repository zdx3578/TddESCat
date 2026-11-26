"""Verify the dependency locks and the vendored build inputs."""

import argparse
import hashlib
import re
import tomllib
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def load(path: Path) -> dict:
    with path.open("rb") as source:
        return tomllib.load(source)


def build_digest(path: Path, manifest: str, license_file: str) -> str:
    files = [path / manifest, path / license_file]
    files.extend(file for file in (path / "src").rglob("*") if file.is_file())
    digest = hashlib.sha256()
    for file in sorted(files):
        digest.update(file.relative_to(path).as_posix().encode() + b"\0")
        digest.update(hashlib.sha256(file.read_bytes()).digest())
    return digest.hexdigest()


def contains_github_git(value: object) -> bool:
    if isinstance(value, dict):
        return "github.com" in str(value.get("git", "")).lower() or any(
            contains_github_git(item) for item in value.values()
        )
    if isinstance(value, list):
        return any(contains_github_git(item) for item in value)
    return (
        isinstance(value, str)
        and value.startswith("git+")
        and "github.com" in value.lower()
    )


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def rust_build_digest(path: Path) -> str:
    return build_digest(path, "Cargo.toml", "LICENSE")


def check_python_source(source, locks):
    name, version, kind = (source[key] for key in ("name", "version", "kind"))
    lock_name = source.get(
        "lock_path", "python/uv.lock" if kind == "pypi" else "python/compute/uv.lock"
    )
    if lock_name not in locks:
        locks[lock_name] = load(ROOT / lock_name)["package"]
    packages = [
        package
        for package in locks[lock_name]
        if package["name"] == name and package["version"] == version
    ]
    if "index" in source:
        packages = [
            package
            for package in packages
            if package["source"].get("registry") == source["index"]
        ]
    require(len(packages) == 1, f"Python lock drift: {name}")
    package = packages[0]
    archive = package.get("sdist")
    if archive is not None:
        require(kind != "compute-wheel", f"Expected a wheel-only release: {name}")
        require(
            archive["hash"] == f"sha256:{source['archive_sha256']}",
            f"PyPI source digest mismatch: {name}",
        )
    else:
        require(
            source["archive_sha256"] == source["wheel_sha256"],
            f"Wheel source digest mismatch: {name}",
        )
    matching = [
        wheel
        for wheel in package["wheels"]
        if wheel["hash"] == f"sha256:{source['wheel_sha256']}"
    ]
    require(bool(matching), f"Python wheel digest mismatch: {name}")
    if kind == "compute-wheel":
        require(
            any(
                Path(unquote(urlsplit(wheel["url"]).path)).name == source["archive"]
                for wheel in matching
            ),
            f"Python wheel distribution mismatch: {name}",
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    python_locks = {}
    julia = load(ROOT / "julia/TddESCat/Manifest.toml")["deps"]
    cargo = load(ROOT / "Cargo.lock")
    cargo_packages = {
        (item["name"], item["version"]): item for item in cargo["package"]
    }
    manifests = [
        ROOT / "Cargo.toml",
        *(ROOT / "third_party").rglob("Cargo.toml"),
        *(ROOT / "rust").rglob("Cargo.toml"),
    ]
    for manifest in manifests:
        require(
            not contains_github_git(load(manifest)),
            f"Unresolved GitHub dependency: {manifest}",
        )
    require(
        not contains_github_git(cargo), "Unresolved GitHub dependency in Cargo.lock"
    )
    egg_patch = load(ROOT / "Cargo.toml")["patch"]["crates-io"]["egg"]
    require(
        egg_patch == {"path": "third_party/egg"}, "Expected the pinned local egg patch"
    )

    for source in load(args.config)["source"]:
        name, version, kind = (source[key] for key in ("name", "version", "kind"))
        require(
            bool(re.fullmatch(r"[0-9a-f]{64}", source["archive_sha256"])),
            f"Missing archive digest: {name}",
        )
        if kind in ("pypi", "compute-pypi", "compute-wheel"):
            check_python_source(source, python_locks)
        elif kind == "julia":
            package = julia[name][0]
            require(
                package["version"] == version
                and package["git-tree-sha1"] == source["tree_sha1"],
                f"Julia version or source tree drift: {name}",
            )
            if name in ("Compose", "Galley"):
                require(
                    (package.get("repo-url"), package.get("repo-rev"))
                    == (source["repository"], source["revision"]),
                    f"Julia repository revision drift: {name}",
                )
            if name == "Galley":
                require("Finch" not in julia, "Galley includes Finch internally")
        elif kind == "vendored":
            path = ROOT / source["local_path"]
            require(
                "source" not in cargo_packages[(name, version)],
                f"Expected local crate: {name}",
            )
            require(
                (path / source["license_path"]).is_file(), f"Missing license: {name}"
            )
            require(
                rust_build_digest(path) == source["build_sha256"],
                f"Rust build input drift: {name}",
            )
            if "upstream_cargo_lock_sha256" in source:
                require(
                    hashlib.sha256((path / "Cargo.lock").read_bytes()).hexdigest()
                    == source["upstream_cargo_lock_sha256"],
                    f"Upstream Cargo.lock drift: {name}",
                )
        elif kind == "julia-vendored":
            path = ROOT / source["local_path"]
            package = julia[name][0]
            require(
                package["version"] == version
                and (ROOT / "julia/TddESCat" / package["path"]).resolve() == path
                and load(path / "Project.toml")["uuid"] == package["uuid"],
                f"Expected the pinned local Julia package: {name}",
            )
            require(
                build_digest(path, "Project.toml", source["license_path"])
                == source["build_sha256"],
                f"Julia build input drift: {name}",
            )
        else:
            raise SystemExit(f"Unknown source kind: {kind}")
        print(f"{name} {version}: {kind} source lock verified")


if __name__ == "__main__":
    main()
