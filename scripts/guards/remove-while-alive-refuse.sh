#!/usr/bin/env bash
# Guard: remove-while-alive-refuse
#
# Verifies that `clier remove` refuses to delete a working copy while a run
# is alive in that workspace, and that the refusal names the alive run-id.
#
# Invokes the real `clier` CLI against the user's current environment
# (workspace and authenticated org). Emits a single report-v2 `check`
# object (evidence.kind: scenario) to stdout. Progress logs go to stderr.
#
# Exit codes:
#   0  - scenario completed and result was emitted (pass, fail, or error)
#   1+ - script itself malfunctioned (bug in the harness, not the CLI)

set -u

# ─── config ──────────────────────────────────────────────────────────
CHECK_ID="guards.remove-while-alive-refuse"
PHASE="guards"
TITLE='Scenario — `remove` refuses when a run is alive'
PRECONDITION="clean workspace, team not yet cloned in current workspace"
EXPECTED="remove refused with the alive run-id in stderr"
TEAM="@clier/hello-claude"
TEAM_CLONE="@clier/hello-claude@1"   # CLI currently requires explicit @version on clone

# ─── tool dependencies ───────────────────────────────────────────────
for bin in clier jq python3; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "remove-while-alive-refuse: missing required binary: $bin" >&2
    exit 1
  fi
done

# ─── helpers ─────────────────────────────────────────────────────────
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
log()    { echo "[$(date +%H:%M:%S)] $*" >&2; }

STEPS_FILE=$(mktemp)
echo '[]' > "$STEPS_FILE"

RUN_ID=""
ACTUAL="(scenario did not complete)"

cleanup_fs() {
  rm -f "$STEPS_FILE" "$STEPS_FILE.new" /tmp/clier-qa-*.err /tmp/clier-qa-*.out 2>/dev/null
}
cleanup_workspace() {
  # Best-effort teardown. Silently tolerate each step failing; by the end
  # either everything is gone or the system is in a state where the next
  # run's pre-cleanup will finish the job.

  # Match runs by their working_copy_path (contains "owner.name")
  local ws_segment
  ws_segment=$(echo "$TEAM" | sed 's|/|.|')   # @clier/hello-claude → @clier.hello-claude
  local rids
  rids=$(clier run list 2>/dev/null | jq -r --arg ws "$ws_segment" \
    '.items[]? | select(.working_copy_path | test($ws)) | .run_id' 2>/dev/null || true)
  for rid in $rids; do
    clier run stop "$rid" >/dev/null 2>&1 || true
  done

  clier remove "$TEAM" >/dev/null 2>&1 || true
}
trap 'cleanup_workspace; cleanup_fs' EXIT

# push_step <role> <label> <status> <extras-json>
push_step() {
  local role="$1" label="$2" status="$3" extras="${4:-{\}}"
  jq --arg role "$role" --arg label "$label" --arg status "$status" --argjson extras "$extras" \
     '. += [({role:$role, label:$label, status:$status}) + $extras]' \
     "$STEPS_FILE" > "$STEPS_FILE.new" && mv "$STEPS_FILE.new" "$STEPS_FILE"
}

# emit <overall-status> [fail_note]
emit() {
  local overall="$1"
  local fail_note="${2:-}"
  local steps
  steps=$(cat "$STEPS_FILE")

  local base
  base=$(jq -n \
    --arg id "$CHECK_ID" --arg phase "$PHASE" --arg title "$TITLE" \
    --arg status "$overall" --arg pre "$PRECONDITION" \
    --arg exp "$EXPECTED" --arg act "$ACTUAL" \
    --argjson steps "$steps" \
    '{
      id: $id,
      phase: $phase,
      source: "script",
      status: $status,
      title: $title,
      evidence: {
        kind: "scenario",
        precondition: $pre,
        expected_outcome: $exp,
        actual_outcome: $act,
        steps: $steps
      }
    }')

  if [ "$overall" = "error" ] && [ -n "$fail_note" ]; then
    echo "$base" | jq --arg d "$fail_note" '. + {error_detail: $d}'
  elif [ "$overall" = "fail" ] && [ -n "$fail_note" ]; then
    echo "$base" | jq --arg d "$fail_note" '. + {fail_note: $d}'
  else
    echo "$base"
  fi
}

# ─── pre-cleanup (silently clear any residue from prior interrupted runs) ─
log "pre-cleanup: dropping any stale workspace for $TEAM"
cleanup_workspace

# ─── STEP 1: setup — clone ────────────────────────────────────────────
log "1/4 clone $TEAM"
T0=$(now_ms)
clone_stdout=$(clier clone "$TEAM_CLONE" 2>/tmp/clier-qa-clone.err); clone_exit=$?
T1=$(now_ms)
clone_stderr=$(cat /tmp/clier-qa-clone.err)
dur=$((T1 - T0))

if [ $clone_exit -ne 0 ]; then
  push_step setup "Clone team" "error" \
    "$(jq -n --arg cmd "clier clone $TEAM_CLONE" --argjson exit "$clone_exit" --arg err "$clone_stderr" --argjson d "$dur" \
       '{command:$cmd, exit_code:$exit, stderr_excerpt:$err, duration_ms:$d, error_detail:("clone exited " + ($exit|tostring))}')"
  ACTUAL="setup failed: clone returned $clone_exit"
  emit "error" "Setup failed: could not clone $TEAM_CLONE — $clone_stderr"
  exit 0
fi
push_step setup "Clone team" "pass" \
  "$(jq -n --arg cmd "clier clone $TEAM_CLONE" --argjson exit 0 --argjson d "$dur" \
     '{command:$cmd, exit_code:$exit, duration_ms:$d}')"

# ─── STEP 2: setup — run start (capture run_id) ───────────────────────
log "2/4 run start $TEAM"
T0=$(now_ms)
start_stdout=$(clier run start "$TEAM" 2>/tmp/clier-qa-start.err); start_exit=$?
T1=$(now_ms)
start_stderr=$(cat /tmp/clier-qa-start.err)
dur=$((T1 - T0))

if [ $start_exit -ne 0 ]; then
  push_step setup "Start a run to create alive state" "error" \
    "$(jq -n --arg cmd "clier run start $TEAM" --argjson exit "$start_exit" --arg err "$start_stderr" --argjson d "$dur" \
       '{command:$cmd, exit_code:$exit, stderr_excerpt:$err, duration_ms:$d, error_detail:("run start exited " + ($exit|tostring))}')"
  ACTUAL="setup failed: run start returned $start_exit"
  emit "error" "Setup failed: run start — $start_stderr"
  exit 0
fi

RUN_ID=$(echo "$start_stdout" | jq -r '.run_id // empty' 2>/dev/null || true)
if [ -z "$RUN_ID" ]; then
  push_step setup "Start a run to create alive state" "error" \
    "$(jq -n --arg cmd "clier run start $TEAM" --argjson exit 0 --arg out "$start_stdout" --argjson d "$dur" \
       '{command:$cmd, exit_code:$exit, stdout_excerpt:$out, duration_ms:$d, error_detail:"run_id missing from run start output"}')"
  ACTUAL="setup failed: run_id not present in run start output"
  emit "error" "Setup failed: no .run_id in run start output"
  exit 0
fi

push_step setup "Start a run to create alive state" "pass" \
  "$(jq -n --arg cmd "clier run start $TEAM" --argjson exit 0 --argjson d "$dur" --arg rid "$RUN_ID" \
     '{command:$cmd, exit_code:$exit, duration_ms:$d, captured:{run_id:$rid}}')"

# ─── STEP 3: assertion — remove should refuse ──────────────────────────
log "3/4 remove $TEAM (expecting refusal that mentions $RUN_ID)"
T0=$(now_ms)
rm_stdout=$(clier remove "$TEAM" 2>/tmp/clier-qa-rm.err); rm_exit=$?
T1=$(now_ms)
rm_stderr=$(cat /tmp/clier-qa-rm.err)
dur=$((T1 - T0))

# Expectations
exit_ok="false"
[ $rm_exit -ne 0 ] && exit_ok="true"

stderr_ok="false"
if echo "$rm_stderr" | grep -qF "$RUN_ID"; then stderr_ok="true"; fi

assertion_pass="fail"
if [ "$exit_ok" = "true" ] && [ "$stderr_ok" = "true" ]; then
  assertion_pass="pass"
fi

expectations=$(jq -n \
  --argjson exit "$rm_exit" --arg rid "$RUN_ID" \
  --arg exit_ok "$exit_ok" --arg stderr_ok "$stderr_ok" \
  '[
    {kind:"exit_code",       expected:"non-zero", actual:$exit, pass:($exit_ok=="true")},
    {kind:"stderr_contains", expected:$rid,                    pass:($stderr_ok=="true")}
  ]')

push_step assertion "Remove is refused and names the alive run-id" "$assertion_pass" \
  "$(jq -n --arg cmd "clier remove $TEAM" --argjson exit "$rm_exit" --arg err "$rm_stderr" --argjson d "$dur" --argjson exp "$expectations" \
     '{command:$cmd, exit_code:$exit, stderr_excerpt:$err, duration_ms:$d, expectations:$exp}')"

if [ "$assertion_pass" = "pass" ]; then
  ACTUAL="remove refused with the alive run-id in stderr"
else
  ACTUAL="exit_code=$rm_exit; stderr_contains_run_id=$stderr_ok"
fi

# ─── STEP 4: teardown — stop run and remove workspace ─────────────────
log "4/4 stop $RUN_ID && remove $TEAM"
T0=$(now_ms)
stop_err=""
rm_err=""
clier run stop "$RUN_ID" >/dev/null 2>/tmp/clier-qa-stop.err || stop_err=$(cat /tmp/clier-qa-stop.err)
clier remove "$TEAM"   >/dev/null 2>/tmp/clier-qa-rm2.err   || rm_err=$(cat /tmp/clier-qa-rm2.err)
T1=$(now_ms)
dur=$((T1 - T0))

if [ -z "$stop_err" ] && [ -z "$rm_err" ]; then
  push_step teardown "Stop run and remove workspace" "pass" \
    "$(jq -n --arg cmd "clier run stop $RUN_ID && clier remove $TEAM" --argjson exit 0 --argjson d "$dur" \
       '{command:$cmd, exit_code:$exit, duration_ms:$d}')"
  # success path — clear RUN_ID so EXIT trap won't double-teardown
  RUN_ID=""
else
  combined_err="stop: ${stop_err:-ok}; remove: ${rm_err:-ok}"
  push_step teardown "Stop run and remove workspace" "fail" \
    "$(jq -n --arg cmd "clier run stop $RUN_ID && clier remove $TEAM" --argjson exit 1 --arg err "$combined_err" --argjson d "$dur" \
       '{command:$cmd, exit_code:$exit, stderr_excerpt:$err, duration_ms:$d}')"
fi

# ─── final emit ───────────────────────────────────────────────────────
if [ "$assertion_pass" = "pass" ]; then
  emit "pass"
else
  emit "fail" "CLI did not refuse remove while run was alive (exit=$rm_exit, stderr_contains_run_id=$stderr_ok)"
fi
