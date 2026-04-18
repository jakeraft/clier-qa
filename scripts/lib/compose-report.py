#!/usr/bin/env python3
"""Compose a report-v1 JSON from scripted scenarios and agent findings.

Writes reports/<run-id>.json, updates reports/index.json, validates against
schema/report-v1.schema.json.

Section A (exploration) comes from --findings-file <path> and/or
--exploration-summary "<one narrative paragraph>".

Section B (scenarios) comes from one or more --scenario <path> arguments.
Each scenario file holds one scenario object (or a JSON array of scenarios).

Typical use:
    ./scripts/scenarios/skill.create-and-delete.sh > /tmp/s.json
    python3 scripts/lib/compose-report.py \
        --scenario /tmp/s.json \
        --findings-file findings.json \
        --exploration-summary "..." \
        --summary "hello-world run"
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
REPO = HERE.parent.parent
SCHEMA_PATH = REPO / "schema" / "report-v1.schema.json"
REPORTS = REPO / "reports"


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
    return datetime.now().strftime("%Y-%m-%dT%H%M%S")


def load_array_or_one(path: str) -> list[dict]:
    data = json.loads(pathlib.Path(path).read_text())
    return data if isinstance(data, list) else [data]


def counts(items: list[dict]) -> dict:
    c = {"total": len(items), "pass": 0, "fail": 0, "skip": 0, "error": 0}
    for it in items:
        c[it["status"]] = c.get(it["status"], 0) + 1
    return c


def verdict(c_f: dict, c_s: dict) -> str:
    return "pass" if (c_f["fail"] == 0 and c_f["error"] == 0
                      and c_s["fail"] == 0 and c_s["error"] == 0) else "fail"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario", action="append", default=[],
                    help="Path to a scenario JSON file (repeatable)")
    ap.add_argument("--findings-file", default=None,
                    help="Optional JSON file holding the findings array")
    ap.add_argument("--exploration-summary", default="",
                    help="One-paragraph narrative for Section A")
    ap.add_argument("--run-id", default=None)
    ap.add_argument("--started-at", default=None)
    ap.add_argument("--finished-at", default=None)
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

    scenarios: list[dict] = []
    for p in args.scenario:
        scenarios.extend(load_array_or_one(p))

    findings: list[dict] = []
    if args.findings_file:
        findings = load_array_or_one(args.findings_file)

    if not scenarios and not findings:
        print("compose-report: need at least one --scenario or --findings-file", file=sys.stderr)
        return 2

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

    report = {
        "schema_version": 1,
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
        "exploration": {
            "summary": args.exploration_summary or "(no exploration narrative)",
            "findings": findings,
        },
        "scenarios": scenarios,
    }

    # validate
    schema = json.loads(SCHEMA_PATH.read_text())
    errors = list(Draft202012Validator(schema).iter_errors(report))
    if errors:
        print("compose-report: report is INVALID:", file=sys.stderr)
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

    c_f = counts(findings)
    c_s = counts(scenarios)
    entry = {
        "id": rid,
        "schema_version": 1,
        "clier_version": clier_v,
        "summary": args.summary,
        "verdict": verdict(c_f, c_s),
        "counts": {"findings": c_f, "scenarios": c_s},
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
