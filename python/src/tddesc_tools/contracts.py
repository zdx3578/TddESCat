"""Load and validate the repository's versioned, offline JSON Schema registry."""

import argparse
import json
from pathlib import Path

from jsonschema import Draft202012Validator
from referencing import Registry, Resource


def references(node):
    if isinstance(node, dict):
        if "$ref" in node:
            yield node["$ref"]
        for value in node.values():
            yield from references(value)
    elif isinstance(node, list):
        for value in node:
            yield from references(value)


class Contracts:
    def __init__(self, schema_dir: Path):
        self.schemas = {
            path.name.removesuffix(".schema.json"): json.loads(path.read_bytes())
            for path in sorted(schema_dir.glob("*.schema.json"))
        }
        if not self.schemas:
            raise ValueError(f"No schemas at {schema_dir}")
        registry = Registry().with_resources(
            (schema["$id"], Resource.from_contents(schema))
            for schema in self.schemas.values()
        )
        for schema in self.schemas.values():
            Draft202012Validator.check_schema(schema)
            resolver = registry.resolver(base_uri=schema["$id"])
            for reference in references(schema):
                resolver.lookup(reference)
        self.registry = registry

    def validate(self, name: str, document) -> None:
        Draft202012Validator(self.schemas[name], registry=self.registry).validate(
            document
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--schemas", type=Path, default=Path("protocol/v1"))
    parser.add_argument("--document", nargs=2, metavar=("SCHEMA", "JSON"))
    args = parser.parse_args()
    contracts = Contracts(args.schemas)
    if args.document:
        name, filename = args.document
        contracts.validate(name, json.loads(Path(filename).read_bytes()))
    print(f"Validated {len(contracts.schemas)} versioned schemas")


if __name__ == "__main__":
    main()
