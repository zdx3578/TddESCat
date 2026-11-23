"""Compile the locked E-Stitch workspace and run a bounded upstream search."""

import argparse
import json
import subprocess
import sys
import tomllib
from pathlib import Path
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    with args.config.open("rb") as source:
        runtime = tomllib.load(source)
    cargo = runtime["cargo"]["executable"]
    actual = subprocess.check_output([cargo, "--version"], cwd=ROOT, text=True)
    if actual.split()[1] != runtime["cargo"]["version"]:
        raise SystemExit(f"Unexpected Cargo version: {actual.strip()}")
    subprocess.run([cargo, "check", "--locked", "--workspace"], cwd=ROOT, check=True)

    with TemporaryDirectory() as directory:
        input_path = Path(directory) / "programs.json"
        output_path = Path(directory) / "result.json"
        programs = [f"(f (g c{2 * i:02}) (g c{2 * i + 1:02}))" for i in range(16)]
        input_path.write_text(json.dumps(programs), encoding="utf-8")
        subprocess.run(
            [
                cargo,
                "run",
                "--locked",
                "-p",
                "egg-stitch",
                "--bin",
                "egg-stitch",
                "--",
                "--language",
                "op-children-db",
                "--search",
                "best-first",
                "--num-abstractions",
                "1",
                "--num-steps",
                "1000",
                "--seed",
                "1729",
                "--input",
                input_path,
                "--output",
                output_path,
            ],
            cwd=ROOT,
            check=True,
        )
        result = json.loads(output_path.read_text(encoding="utf-8"))
        if (
            result["initial_cost"] != 81
            or not result["library"]
            or not 0 < result["final_cost"] < result["initial_cost"]
        ):
            raise SystemExit(
                "E-Stitch smoke did not discover a positive-gain definition"
            )
        subprocess.run(
            [
                sys.executable,
                "third_party/egg-stitch/scripts/check_equiv.py",
                output_path,
            ],
            cwd=ROOT,
            check=True,
        )
        print(
            f"E-Stitch smoke passed: cost {result['initial_cost']} -> {result['final_cost']}"
        )


if __name__ == "__main__":
    main()
