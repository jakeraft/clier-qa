#!/usr/bin/env bash
# Driver — runs every scenario script, collects their v2 check fragments,
# and composes a single report.json via scripts/lib/compose-report.py.
#
# Usage:
#   scripts/qa.sh [--summary "<one-line>"] [--notes-file <path>]
#
# stdout: the generated run-id (so callers can chain follow-up actions)
# stderr: per-scenario progress

set -u

SUMMARY="Scenario sweep — $(basename "$PWD")"
NOTES_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --summary)    SUMMARY="$2"; shift 2 ;;
    --notes-file) NOTES_FILE="$2"; shift 2 ;;
    *) echo "qa.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SCENARIOS_DIR="$HERE/scenarios"
COMPOSE="$HERE/lib/compose-report.py"

if [ ! -d "$SCENARIOS_DIR" ]; then
  echo "qa.sh: scenarios dir not found: $SCENARIOS_DIR" >&2
  exit 1
fi

FRAG_DIR=$(mktemp -d)
trap 'rm -rf "$FRAG_DIR"' EXIT

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

# ─── run each scenario ────────────────────────────────────────────
pass=0; fail=0; errored=0; total=0
check_args=()

for scenario in "$SCENARIOS_DIR"/*.sh; do
  [ -f "$scenario" ] || continue
  name=$(basename "$scenario" .sh)
  total=$((total + 1))
  frag="$FRAG_DIR/$name.json"
  gerr="$FRAG_DIR/$name.stderr.log"

  log "→ $name"
  if "$scenario" >"$frag" 2>"$gerr"; then
    status=$(jq -r '.status // "error"' "$frag" 2>/dev/null || echo error)
    case "$status" in
      pass)  pass=$((pass+1));    log "  $name: PASS"  ;;
      fail)  fail=$((fail+1));    log "  $name: FAIL"  ;;
      error) errored=$((errored+1)); log "  $name: ERROR" ;;
      skip)  log "  $name: SKIP" ;;
      *)     errored=$((errored+1)); log "  $name: UNKNOWN status=$status" ;;
    esac
    check_args+=(--check "$frag")
  else
    # scenario script itself crashed
    errored=$((errored+1))
    log "  $name: SCRIPT CRASH (exit $?); see $gerr"
    # keep any partial fragment around if valid JSON, otherwise skip
    if jq empty "$frag" >/dev/null 2>&1; then
      check_args+=(--check "$frag")
    fi
  fi
done

log "summary: $total scenarios · $pass pass / $fail fail / $errored error"

if [ ${#check_args[@]} -eq 0 ]; then
  log "no usable fragments produced — aborting compose"
  exit 1
fi

# ─── compose into one report ───────────────────────────────────────
compose_args=("${check_args[@]}" --summary "$SUMMARY")
[ -n "$NOTES_FILE" ] && compose_args+=(--notes-file "$NOTES_FILE")

cd "$REPO"
rid=$(python3 "$COMPOSE" "${compose_args[@]}")
log "composed report: reports/$rid.json"

echo "$rid"
