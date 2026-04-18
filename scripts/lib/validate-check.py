#!/usr/bin/env python3
"""Validate a single report-v1 scenario or finding fragment from stdin.

Usage:
    ./scripts/scenarios/<scenario>.sh | python3 scripts/lib/validate-check.py [--kind scenario|finding]

--kind defaults to "scenario". Prints VALID or lists errors on stderr.
Exits 0 on success, 1 on validation failure.
"""
from __future__ import annotations
import argparse
import json
import pathlib
import sys

from jsonschema import Draft202012Validator
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012

HERE = pathlib.Path(__file__).resolve().parent
SCHEMA_PATH = HERE.parent.parent / "schema" / "report-v1.schema.json"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--kind", choices=["scenario", "finding"], default="scenario")
    args = ap.parse_args()

    try:
        fragment = json.loads(sys.stdin.read())
    except json.JSONDecodeError as e:
        print(f"validate-check: stdin is not valid JSON: {e}", file=sys.stderr)
        return 1

    schema = json.loads(SCHEMA_PATH.read_text())
    resource = Resource(contents=schema, specification=DRAFT202012)
    registry = Registry().with_resource(uri=schema["$id"], resource=resource)

    ref_schema = {"$ref": f"{schema['$id']}#/$defs/{args.kind}"}
    validator = Draft202012Validator(ref_schema, registry=registry)

    errors = list(validator.iter_errors(fragment))
    if not errors:
        print(f"VALID ({args.kind})", file=sys.stderr)
        return 0

    for err in errors[:10]:
        path = "/".join(str(p) for p in err.absolute_path) or "(root)"
        print(f"INVALID at {path}: {err.message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
