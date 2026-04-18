#!/usr/bin/env bash
# Scenario: skill.create-and-delete
#
# The simplest resource-lifecycle verification for the clier CLI:
#   1. create a skill (action)
#   2. confirm it's retrievable (assertion)
#   3. delete it                 (action)
#   4. confirm it's gone         (assertion)
#
# Emits a single report-v1 `scenario` object on stdout.
# Stderr carries per-step progress. Exit 0 on normal completion
# (pass / fail / error); exit != 0 only on script malfunction.

set -u

# ─── scenario config ──────────────────────────────────────────────
SCENARIO_ID="skill.create-and-delete"
TITLE='Scenario — create skill, confirm, delete, confirm gone'
PRECONDITION="authenticated clier session; target name not yet taken"
EXPECTED="skill appears after create; not-found after delete"

TS=$(date +%Y%m%d%H%M%S)
SKILL_NAME="qa-hello-$TS"
SKILL_CONTENT=$'---\nname: qa-hello\ndescription: QA hello-world probe. Safe to delete.\n---\n\n# QA probe'
SKILL_SUMMARY="QA hello-world probe — safe to delete"
OWNER=""                    # resolved from create output
FULL_REF=""                 # <owner>/<name>

# ─── dependencies ─────────────────────────────────────────────────
for bin in clier jq python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing: $bin" >&2; exit 1; }
done

# ─── helpers ──────────────────────────────────────────────────────
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
log()    { echo "[$(date +%H:%M:%S)] $*" >&2; }

STEPS_FILE=$(mktemp)
echo '[]' > "$STEPS_FILE"

ACTUAL="(scenario did not complete)"

cleanup() {
  if [ -n "$FULL_REF" ]; then
    clier delete "$FULL_REF" >/dev/null 2>&1 || true
  fi
  rm -f "$STEPS_FILE" "$STEPS_FILE.new" /tmp/clier-qa-*.out /tmp/clier-qa-*.err 2>/dev/null
}
trap cleanup EXIT

push_step() {
  local role="$1" label="$2" status="$3" extras="${4:-{\}}"
  jq --arg r "$role" --arg l "$label" --arg s "$status" --argjson e "$extras" \
     '. += [({role:$r, label:$l, status:$s}) + $e]' \
     "$STEPS_FILE" > "$STEPS_FILE.new" && mv "$STEPS_FILE.new" "$STEPS_FILE"
}

emit() {
  local overall="$1"
  local detail="${2:-}"
  local steps; steps=$(cat "$STEPS_FILE")

  local obj
  obj=$(jq -n \
    --arg id "$SCENARIO_ID" --arg title "$TITLE" --arg status "$overall" \
    --arg pre "$PRECONDITION" --arg exp "$EXPECTED" --arg act "$ACTUAL" \
    --argjson steps "$steps" \
    '{
      id: $id, title: $title, source: "script", status: $status,
      evidence: {
        kind: "scenario",
        precondition: $pre,
        expected_outcome: $exp,
        actual_outcome: $act,
        steps: $steps
      }
    }')

  if [ "$overall" = "error" ] && [ -n "$detail" ]; then
    echo "$obj" | jq --arg d "$detail" '. + {error_detail: $d}'
  elif [ "$overall" = "fail" ] && [ -n "$detail" ]; then
    echo "$obj" | jq --arg d "$detail" '. + {fail_note: $d}'
  else
    echo "$obj"
  fi
}

# ─── 1/4 — action: create skill ───────────────────────────────────
log "1/4 create skill $SKILL_NAME"
T0=$(now_ms)
create_out=$(clier create skill \
  --name "$SKILL_NAME" \
  --content "$SKILL_CONTENT" \
  --summary "$SKILL_SUMMARY" \
  2>/tmp/clier-qa-create.err); create_exit=$?
T1=$(now_ms); dur=$((T1 - T0))
create_err=$(cat /tmp/clier-qa-create.err)

if [ $create_exit -ne 0 ]; then
  push_step action "Create skill" "error" \
    "$(jq -n --arg c "clier create skill --name $SKILL_NAME ..." --argjson e "$create_exit" --arg s "$create_err" --argjson d "$dur" \
       '{command:$c, exit_code:$e, stderr_excerpt:$s, duration_ms:$d, error_detail:("create exited " + ($e|tostring))}')"
  ACTUAL="setup failed: create returned $create_exit"
  emit "error" "create skill failed — $create_err"
  exit 0
fi

OWNER=$(echo "$create_out" | jq -r '.metadata.owner_name // .owner // empty' 2>/dev/null)
RESOLVED_NAME=$(echo "$create_out" | jq -r '.metadata.name // .name // empty' 2>/dev/null)
if [ -z "$OWNER" ] || [ -z "$RESOLVED_NAME" ]; then
  push_step action "Create skill" "error" \
    "$(jq -n --arg c "clier create skill ..." --argjson e 0 --arg o "$create_out" --argjson d "$dur" \
       '{command:$c, exit_code:$e, stdout_excerpt:$o, duration_ms:$d, error_detail:"could not extract owner/name from create output"}')"
  ACTUAL="setup failed: owner/name missing from create output"
  emit "error" "create output lacked owner/name"
  exit 0
fi
FULL_REF="$OWNER/$RESOLVED_NAME"

push_step action "Create skill" "pass" \
  "$(jq -n --arg c "clier create skill --name $SKILL_NAME ..." --argjson e 0 --argjson d "$dur" --arg ref "$FULL_REF" \
     '{command:$c, exit_code:$e, duration_ms:$d, captured:{ref:$ref}}')"

# ─── 2/4 — assertion: get confirms presence ───────────────────────
log "2/4 get $FULL_REF (expect present)"
T0=$(now_ms)
get1_out=$(clier get "$FULL_REF" 2>/tmp/clier-qa-get1.err); get1_exit=$?
T1=$(now_ms); dur=$((T1 - T0))
get1_err=$(cat /tmp/clier-qa-get1.err)

name_ok="false"
if [ $get1_exit -eq 0 ] && echo "$get1_out" | jq -e --arg n "$RESOLVED_NAME" '.metadata.name == $n' >/dev/null 2>&1; then
  name_ok="true"
fi

present_status="fail"
[ $get1_exit -eq 0 ] && [ "$name_ok" = "true" ] && present_status="pass"

expectations=$(jq -n --argjson exit "$get1_exit" --arg name "$RESOLVED_NAME" --arg nameok "$name_ok" \
  '[
    {kind:"exit_code",       expected:0,     actual:$exit,  pass:($exit|tostring=="0")},
    {kind:"json_path_equals",path:"$.metadata.name", expected:$name, pass:($nameok=="true")}
  ]')

push_step assertion "Skill is retrievable after create" "$present_status" \
  "$(jq -n --arg c "clier get $FULL_REF" --argjson e "$get1_exit" --arg s "$get1_err" --argjson d "$dur" --argjson exp "$expectations" \
     '{command:$c, exit_code:$e, stderr_excerpt:$s, duration_ms:$d, expectations:$exp}')"

if [ "$present_status" != "pass" ]; then
  ACTUAL="skill not retrievable after create (exit=$get1_exit, name_match=$name_ok)"
  emit "fail" "Expected get to return the new skill, but got exit $get1_exit"
  exit 0
fi

# ─── 3/4 — action: delete ─────────────────────────────────────────
log "3/4 delete $FULL_REF"
T0=$(now_ms)
del_out=$(clier delete "$FULL_REF" 2>/tmp/clier-qa-del.err); del_exit=$?
T1=$(now_ms); dur=$((T1 - T0))
del_err=$(cat /tmp/clier-qa-del.err)

if [ $del_exit -ne 0 ]; then
  push_step action "Delete skill" "fail" \
    "$(jq -n --arg c "clier delete $FULL_REF" --argjson e "$del_exit" --arg s "$del_err" --argjson d "$dur" \
       '{command:$c, exit_code:$e, stderr_excerpt:$s, duration_ms:$d}')"
  ACTUAL="delete returned $del_exit"
  emit "fail" "Expected delete to succeed (exit 0), but got $del_exit"
  exit 0
fi

push_step action "Delete skill" "pass" \
  "$(jq -n --arg c "clier delete $FULL_REF" --argjson e 0 --argjson d "$dur" \
     '{command:$c, exit_code:$e, duration_ms:$d}')"

# ─── 4/4 — assertion: get confirms absence ────────────────────────
log "4/4 get $FULL_REF (expect not-found)"
T0=$(now_ms)
get2_out=$(clier get "$FULL_REF" 2>/tmp/clier-qa-get2.err); get2_exit=$?
T1=$(now_ms); dur=$((T1 - T0))
get2_err=$(cat /tmp/clier-qa-get2.err)

missing_ok="false"
[ $get2_exit -ne 0 ] && missing_ok="true"

absent_status="fail"
[ "$missing_ok" = "true" ] && absent_status="pass"

expectations=$(jq -n --argjson exit "$get2_exit" --arg ok "$missing_ok" \
  '[ {kind:"exit_code", expected:"non-zero", actual:$exit, pass:($ok=="true")} ]')

push_step assertion "Skill is gone after delete" "$absent_status" \
  "$(jq -n --arg c "clier get $FULL_REF" --argjson e "$get2_exit" --arg s "$get2_err" --argjson d "$dur" --argjson exp "$expectations" \
     '{command:$c, exit_code:$e, stderr_excerpt:$s, duration_ms:$d, expectations:$exp}')"

# scenario completed successfully — clear FULL_REF so cleanup trap
# doesn't attempt a second delete
FULL_REF=""

if [ "$absent_status" = "pass" ]; then
  ACTUAL="skill present after create; gone after delete"
  emit "pass"
else
  ACTUAL="skill still retrievable after delete (exit=$get2_exit)"
  emit "fail" "Expected get to fail after delete, but it returned exit $get2_exit"
fi
