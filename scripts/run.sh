#!/usr/bin/env bash
# Driver — runs every guard script, collects their v2 check fragments,
# and composes a single report.json via scripts/lib/compose-report.py.
#
# Usage:
#   scripts/run.sh [--summary "<one-line>"] [--notes-file <path>]
#
# stdout: the generated run-id (so callers can chain follow-up actions)
# stderr: per-guard progress

set -u

SUMMARY="Guard sweep — $(basename "$PWD")"
NOTES_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --summary)    SUMMARY="$2"; shift 2 ;;
    --notes-file) NOTES_FILE="$2"; shift 2 ;;
    *) echo "run.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
GUARDS_DIR="$HERE/guards"
COMPOSE="$HERE/lib/compose-report.py"

if [ ! -d "$GUARDS_DIR" ]; then
  echo "run.sh: guards dir not found: $GUARDS_DIR" >&2
  exit 1
fi

FRAG_DIR=$(mktemp -d)
trap 'rm -rf "$FRAG_DIR"' EXIT

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

# ─── run each guard ───────────────────────────────────────────────
pass=0; fail=0; errored=0; total=0
check_args=()

for guard in "$GUARDS_DIR"/*.sh; do
  [ -f "$guard" ] || continue
  name=$(basename "$guard" .sh)
  total=$((total + 1))
  frag="$FRAG_DIR/$name.json"
  gerr="$FRAG_DIR/$name.stderr.log"

  log "→ $name"
  if "$guard" >"$frag" 2>"$gerr"; then
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
    # guard script itself crashed
    errored=$((errored+1))
    log "  $name: SCRIPT CRASH (exit $?); see $gerr"
    # keep any partial fragment around if valid JSON, otherwise skip
    if jq empty "$frag" >/dev/null 2>&1; then
      check_args+=(--check "$frag")
    fi
  fi
done

log "summary: $total guards · $pass pass / $fail fail / $errored error"

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
