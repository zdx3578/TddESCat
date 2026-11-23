"""Verify the dependency locks and the vendored Rust build inputs."""

import argparse
import hashlib
import re
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(path: Path) -> dict:
    with path.open("rb") as source:
        return tomllib.load(source)


def rust_build_digest(path: Path) -> str:
    files = [path / "Cargo.toml", path / "LICENSE"]
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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    python = {item["name"]: item for item in load(ROOT / "python/uv.lock")["package"]}
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
        if kind == "pypi":
            package = python[name]
            require(package["version"] == version, f"Python lock drift: {name}")
            require(
                package["sdist"]["hash"] == f"sha256:{source['archive_sha256']}",
                f"PyPI source digest mismatch: {name}",
            )
            require(
                any(
                    wheel["hash"] == f"sha256:{source['wheel_sha256']}"
                    for wheel in package["wheels"]
                ),
                f"PyPI wheel digest mismatch: {name}",
            )
        elif kind == "julia":
            package = julia[name][0]
            require(
                package["version"] == version
                and package["git-tree-sha1"] == source["tree_sha1"],
                f"Julia version or source tree drift: {name}",
            )
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
        else:
            raise SystemExit(f"Unknown source kind: {kind}")
        print(f"{name} {version}: {kind} source lock verified")


if __name__ == "__main__":
    main()
