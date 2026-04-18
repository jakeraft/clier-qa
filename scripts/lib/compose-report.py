#!/usr/bin/env python3
"""Compose check fragments + agent-produced content into a full report-v2 JSON.

Writes reports/<run-id>.json and updates reports/index.json. Validates the
output against schema/report-v2.schema.json before writing.

Typical use:

    ./scripts/guards/remove-while-alive-refuse.sh > /tmp/check.json
    python3 scripts/lib/compose-report.py \
        --check /tmp/check.json \
        --notes-file /tmp/notes.json \
        --summary "Hello-world pipeline — single guard"
"""
from __future__ import annotations
import argparse
import json
import pathlib
import platform
import subprocess
import sys
import time
from datetime import datetime, timezone

from jsonschema import Draft202012Validator

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent  # scripts/lib/.. /.. → repo root
SCHEMA_PATH = REPO / "schema" / "report-v2.schema.json"
REPORTS = REPO / "reports"

# Taxonomy aligned with qa-checklist phases. Present every phase even if
# the current run exercises only one — the renderer hides empty phases.
DEFAULT_TAXONOMY = {
    "phases": [
        {"id": "setup",         "name": "Setup",                 "order": 0},
        {"id": "agent-surface", "name": "Agent-mode surface",    "order": 1, "stripe": "agent"},
        {"id": "user-surface",  "name": "User-mode surface",     "order": 2, "stripe": "user"},
        {"id": "walk",          "name": "Black-box walk",        "order": 3},
        {"id": "tutorial",      "name": "Tutorial",              "order": 4},
        {"id": "guards",        "name": "Clier-specific guards", "order": 5},
        {"id": "errors",        "name": "Error & conflict",      "order": 6},
        {"id": "consistency",   "name": "Output consistency",    "order": 7},
        {"id": "cleanup",       "name": "Cleanup",               "order": 8},
    ]
}


def detect_clier_version() -> str:
    try:
        out = subprocess.check_output(["clier", "--version"], text=True).strip()
        return out.split()[-1] if out else "unknown"
    except Exception:
        return "unknown"


def detect_os() -> str:
    return f"{platform.system()} {platform.release()}"


def iso_utc(ts: float | None = None) -> str:
    dt = datetime.fromtimestamp(ts, tz=timezone.utc) if ts else datetime.now(timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def default_run_id() -> str:
    # Local time, matches existing report filename style (no separator on time).
    return datetime.now().strftime("%Y-%m-%dT%H%M%S")


def load_fragments(paths: list[str]) -> list[dict]:
    checks: list[dict] = []
    for p in paths:
        data = json.loads(pathlib.Path(p).read_text())
        if isinstance(data, list):
            checks.extend(data)
        else:
            checks.append(data)
    return checks


def derive_counts(checks: list[dict]) -> dict:
    counts = {"total": len(checks), "pass": 0, "fail": 0, "error": 0, "skip": 0}
    for c in checks:
        counts[c["status"]] = counts.get(c["status"], 0) + 1
    return counts


def derive_guidance(checks: list[dict]) -> dict:
    g = {"good": 0, "poor": 0, "missing": 0}
    for c in checks:
        if c.get("guidance"):
            g[c["guidance"]] = g.get(c["guidance"], 0) + 1
    return g


def verdict(counts: dict) -> str:
    return "pass" if counts["fail"] == 0 and counts["error"] == 0 else "fail"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="append", default=[],
                    help="Path to a check-fragment JSON file (repeatable)")
    ap.add_argument("--notes-file", default=None,
                    help="Optional JSON file with notes array")
    ap.add_argument("--artifacts-file", default=None,
                    help="Optional JSON file with artifacts array")
    ap.add_argument("--run-id", default=None)
    ap.add_argument("--started-at", default=None, help="ISO 8601 UTC")
    ap.add_argument("--finished-at", default=None, help="ISO 8601 UTC")
    ap.add_argument("--clier-version", default=None)
    ap.add_argument("--os", default=None, dest="os_str")
    ap.add_argument("--agent-kind", default="claude", choices=["claude", "codex"])
    ap.add_argument("--agent-model", default=None)
    ap.add_argument("--auth-target", default="@clier")
    ap.add_argument("--prefix", default=None)
    ap.add_argument("--modes", default="agent,user",
                    help="comma-separated modes exercised")
    ap.add_argument("--summary", default="QA run",
                    help="One-line summary written into reports/index.json")
    args = ap.parse_args()

    if not args.check:
        print("compose-report: at least one --check is required", file=sys.stderr)
        return 2

    checks = load_fragments(args.check)
    if not checks:
        print("compose-report: no checks loaded from fragments", file=sys.stderr)
        return 2

    notes = json.loads(pathlib.Path(args.notes_file).read_text()) if args.notes_file else []
    artifacts = json.loads(pathlib.Path(args.artifacts_file).read_text()) if args.artifacts_file else []

    rid = args.run_id or default_run_id()
    now = time.time()
    started = args.started_at or iso_utc(now - 5)
    finished = args.finished_at or iso_utc(now)
    clier_v = args.clier_version or detect_clier_version()
    os_str = args.os_str or detect_os()
    prefix = args.prefix or f"qa-{rid.replace('-', '').replace('T', '').replace(':', '')}"
    modes = [m.strip() for m in args.modes.split(",") if m.strip()]

    agent = {"kind": args.agent_kind}
    if args.agent_model:
        agent["model"] = args.agent_model

    report: dict = {
        "schema_version": 2,
        "run": {
            "id": rid,
            "started_at": started,
            "finished_at": finished,
            "environment": {
                "os": os_str,
                "clier_version": clier_v,
                "auth_target": args.auth_target,
                "disposable_prefix": prefix,
                "modes_exercised": modes,
            },
            "agent": agent,
        },
        "taxonomy": DEFAULT_TAXONOMY,
        "checks": checks,
    }
    if notes:
        report["notes"] = notes
    if artifacts:
        report["artifacts"] = artifacts

    # validate
    schema = json.loads(SCHEMA_PATH.read_text())
    errors = list(Draft202012Validator(schema).iter_errors(report))
    if errors:
        print("compose-report: generated report is INVALID:", file=sys.stderr)
        for e in errors[:10]:
            path = "/".join(str(p) for p in e.absolute_path) or "(root)"
            print(f"  at {path}: {e.message}", file=sys.stderr)
        return 1

    # write report file
    REPORTS.mkdir(parents=True, exist_ok=True)
    out_path = REPORTS / f"{rid}.json"
    out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"wrote {out_path.relative_to(REPO)}", file=sys.stderr)

    # update index.json
    idx_path = REPORTS / "index.json"
    try:
        idx = json.loads(idx_path.read_text())
        if not isinstance(idx, list):
            idx = []
    except Exception:
        idx = []

    counts = derive_counts(checks)
    guidance = derive_guidance(checks)
    entry = {
        "id": rid,
        "schema_version": 2,
        "clier_version": clier_v,
        "summary": args.summary,
        "verdict": verdict(counts),
        "counts": counts,
        "guidance": guidance,
    }
    idx = [e for e in idx if isinstance(e, dict) and e.get("id") != rid]
    idx.insert(0, entry)
    idx.sort(key=lambda x: x.get("id", ""), reverse=True)
    idx_path.write_text(json.dumps(idx, ensure_ascii=False, indent=2) + "\n")
    print(f"updated {idx_path.relative_to(REPO)} ({len(idx)} entries)", file=sys.stderr)

    print(rid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
