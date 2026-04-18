#!/usr/bin/env bash
# Driver — runs every scenario in scripts/scenarios/, collects the v1
# fragments, and composes a single report.json via compose-report.py.
#
# Usage:
#   scripts/qa.sh [--summary "<one line>"]
#                 [--findings-file <path>]
#                 [--exploration-summary "<paragraph>"]
#
# stdout: the generated run-id
# stderr: per-scenario progress

set -u

SUMMARY="QA sweep"
FINDINGS_FILE=""
EXPLORATION_SUMMARY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --summary)             SUMMARY="$2"; shift 2 ;;
    --findings-file)       FINDINGS_FILE="$2"; shift 2 ;;
    --exploration-summary) EXPLORATION_SUMMARY="$2"; shift 2 ;;
    *) echo "qa.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SCENARIOS_DIR="$HERE/scenarios"
COMPOSE="$HERE/lib/compose-report.py"

FRAG_DIR=$(mktemp -d)
trap 'rm -rf "$FRAG_DIR"' EXIT
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

pass=0; fail=0; errored=0; total=0
scenario_args=()

for scenario in "$SCENARIOS_DIR"/*.sh; do
  [ -f "$scenario" ] || continue
  name=$(basename "$scenario" .sh)
  total=$((total + 1))
  frag="$FRAG_DIR/$name.json"
  serr="$FRAG_DIR/$name.stderr.log"

  log "→ $name"
  if "$scenario" >"$frag" 2>"$serr"; then
    status=$(jq -r '.status // "error"' "$frag" 2>/dev/null || echo error)
    case "$status" in
      pass)  pass=$((pass+1));       log "  $name: PASS"  ;;
      fail)  fail=$((fail+1));       log "  $name: FAIL"  ;;
      error) errored=$((errored+1)); log "  $name: ERROR" ;;
      skip)                          log "  $name: SKIP"  ;;
      *)     errored=$((errored+1)); log "  $name: UNKNOWN status=$status" ;;
    esac
    scenario_args+=(--scenario "$frag")
  else
    errored=$((errored+1))
    log "  $name: SCRIPT CRASH (exit $?); stderr saved to $serr"
    if jq empty "$frag" >/dev/null 2>&1; then
      scenario_args+=(--scenario "$frag")
    fi
  fi
done

log "summary: $total scenarios · $pass pass / $fail fail / $errored error"

compose_args=("${scenario_args[@]}" --summary "$SUMMARY")
[ -n "$FINDINGS_FILE" ]       && compose_args+=(--findings-file "$FINDINGS_FILE")
[ -n "$EXPLORATION_SUMMARY" ] && compose_args+=(--exploration-summary "$EXPLORATION_SUMMARY")

cd "$REPO"
rid=$(python3 "$COMPOSE" "${compose_args[@]}")
log "composed: reports/$rid.json"
echo "$rid"
