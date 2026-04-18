#!/usr/bin/env python3
"""Validate a single report-v2 check object piped on stdin.

Usage:
    ./scripts/scenarios/<scenario>.sh | python3 scripts/lib/validate-check.py

Exits 0 on success, prints VALID to stderr.
Exits 1 on any validation error, prints details to stderr.
"""
from __future__ import annotations
import json
import pathlib
import sys

from jsonschema import Draft202012Validator
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012

HERE = pathlib.Path(__file__).resolve().parent
SCHEMA_PATH = HERE.parent.parent / "schema" / "report-v2.schema.json"


def main() -> int:
    try:
        fragment = json.loads(sys.stdin.read())
    except json.JSONDecodeError as e:
        print(f"validate-check: stdin is not valid JSON: {e}", file=sys.stderr)
        return 1

    schema = json.loads(SCHEMA_PATH.read_text())
    resource = Resource(contents=schema, specification=DRAFT202012)
    registry = Registry().with_resource(uri=schema["$id"], resource=resource)

    check_ref = {"$ref": f"{schema['$id']}#/$defs/check"}
    validator = Draft202012Validator(check_ref, registry=registry)

    errors = list(validator.iter_errors(fragment))
    if not errors:
        print("VALID", file=sys.stderr)
        return 0

    for err in errors[:10]:
        path = "/".join(str(p) for p in err.absolute_path) or "(root)"
        print(f"INVALID at {path}: {err.message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
