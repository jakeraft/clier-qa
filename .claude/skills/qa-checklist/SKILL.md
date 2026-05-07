---
name: qa-checklist
description: Use whenever you receive a QA request for the clier CLI. Single-agent flow on a pre-authenticated session — sanity check, free-form exploration + tutorial walkthrough + cross-coverage check, publish.
---

# QA Checklist

`clier` is on PATH.

## Six trust points

Every finding answers to one of these:

1. **Orient from nothing** — the core workflow is discoverable from `--help` alone.
2. **Canonical flow holds** — documented flows (especially `clier tutorial`) match actual behaviour.
3. **Failure is loud and named** — errors print on stderr with `error: <status> <title>: <detail>` (or the same shape for client-side validation). The agent discovers its next move from `clier --help`; the CLI does not coach with recovery hints.
4. **State is transparent** — every mutation is queryable via the CLI; no hidden daemon state.
5. **Output is parseable** — JSON stays consistent, `[]` not `null`, RFC3339 timestamps, stable field names.
6. **No leftover state** — disposable resources created during a run can be removed cleanly.

## How you operate

- **Skeptical.** Success means the right server state and parseable output, not just an exit code of 0.
- **Evidence-first.** A finding without concrete I/O is a hypothesis, not a finding. Every `pass` / `fail` / `error` carries — at minimum — `command` plus the relevant `stdout_excerpt` / `stderr_excerpt` / `exit_code` (or a `steps[]` array, or `references[]` for help/tutorial wording). `rationale` is the narrative ("why is this a finding"); evidence is the concrete reproduction. Both required. Bare assertions are not findings — drop or downgrade to `skip` with a `skip_reason`.
- **Honest error classification.** A CLI defect is `status: fail`; a test-machinery failure (auth blip, network timeout) is `status: error`. `fail` requires `fail_note` (schema-enforced); `error` requires `error_detail`; `skip` requires `skip_reason`.
- **Disposable state.** Every resource you create uses the run's unique prefix so cleanup is trivial.
- **Keep going.** A failure becomes evidence, not a stop signal. The run ends only after the report is committed and pushed. Never skip flows, hardcode commands from prior knowledge, ask the user for input, or leave the run half-finished.

## 1. Setup

The session is pre-authenticated by the operator before the run starts — you assume `clier auth status` returns logged-in. If it does not, that is an environment / setup problem, not a CLI defect under test: record `claude.setup.session-missing` `status: error` with the actual `auth status` output as `error_detail`, then continue with read-only paths (skip every step that needs a session: team create / update / delete / star / unstar). Do not try to log in — auth is out of scope for this skill.

1. `clier --version` — confirm. If it fails, add a `claude.setup.version` finding with `status: error` and continue.
2. `clier auth status` — read-only inspection. Capture `auth_target` (the namespace) for the report. If `logged_in: false`, follow the rule above.
3. Capture run metadata: `started_at` (ISO 8601 UTC), `os` (`uname -sr`), `clier_version`, `auth_target`, and `run_id` (`basename "$(dirname "$(pwd)")"`).
4. Disposable prefix: `qa-$(date +%Y%m%d%H%M%S)-claude`.

## 2. Free-form exploration (your QA pass — 6 trust points)

`clier --help` is the source of truth for what commands exist. Discover the surface from there and walk it yourself — this skill does not enumerate commands or flags. The probes below describe *what each trust point looks like in practice* so you know what to prove for each command you find.

### Trust 1 — Orient from nothing
Start at `clier --help` and recurse into `--help` of every subcommand it lists. A new agent must be able to discover the canonical workflow from those pages alone. Surface anything reachable but invisible from help, or visible in help but not actually reachable.

### Trust 2 — Canonical flow holds
Walk every flow the help text or `clier tutorial` declares. For each documented step, run the exact command and judge whether output and resulting server state match what the docs promised.

### Trust 3 — Failure is loud and named
Push every command into invalid input — wrong args, malformed values, missing required flags, immutable fields, unauthorized callers, unknown resources, empty content, out-of-range bounds, simultaneous multi-field violations. The CLI refuses loudly with a single stderr line that names *what* failed (status + title + detail). Multi-field violations surface every offender in one response — no short-circuit on the first one. The CLI does not append recovery hints; the agent rediscovers its next move from `clier --help`. (Auth itself is out of scope — do not run `auth login` / `auth logout` / `auth status` write paths.)

### Trust 4 — State is transparent
For every state-changing command you find, verify there is a read-side command that surfaces the new state (and toggles you can flip back). Mutations with no read-side equivalent are hidden state. Idempotent operations must reach the same final state regardless of how many times you call them.

### Trust 5 — Output is parseable
On success, every command emits valid JSON on stdout. Inspect for empty arrays as `[]` (never `null`), RFC3339 timestamps, stable field names across calls. Errors print on stderr starting with `error: ` and exit non-zero — server errors as one summary line, client-side validation may add a usage / suggestion line.

### Trust 6 — No leftover state
Every disposable resource you create uses your `qa-...-claude` prefix so cleanup is auditable. After lifecycle-terminating commands (run stop, team delete, etc.), the surface goes back to its pre-run state — `clier run stop` removes the wrapper dir (`~/.clier/runs/<run_id>/`) entirely (ADR-0004 §4.6), and `team delete` clears the server-side row. Inspect for orphans before you finish.

Build findings in memory as you go. **Every id starts with `claude.<area>.<slug>`** (e.g. `claude.team.crud-lifecycle`).

## 3. Tutorial walkthrough

`clier tutorial` is the canonical end-to-end script the CLI publishes for first-time users — its output *is* the step list. Read it once and walk it:

- For each step the tutorial declares, run the exact command shown.
- Judge text-vs-behaviour fidelity. Divergence between what the tutorial says and what the CLI does → `claude.tutorial.<step-id>` `status: fail`.
- If a step requires interactive input (e.g. attaching into a tmux session), record `status: skip` with `skip_reason` and continue.
- Use your `qa-...-claude` prefix wherever the tutorial asks you to invent your own resource.

## 4. Cross-coverage check

`clier tutorial` is intentionally a *minimum first-run path* — five
minutes, the happy run lifecycle (auth/list/start/tell/capture/attach/
stop). Commands beyond that path live in `clier <command> --help` as
the source of truth and are exercised by free-form (§2). Cross-
coverage therefore checks symmetry of the *tutorial path itself*, not
of the whole command surface.

Record only:

- **Tutorial step the tutorial declares but free-form did not actually
  walk** → `claude.coverage.tutorial-step-untested`, name the step.
- **Tutorial step whose runtime behaviour diverges from the
  tutorial's text** → already a Trust 2 fail; cite that finding here
  with `claude.coverage.tutorial-step-drift`.

Do **not** record a finding because free-form covered commands the
tutorial does not walk (team create / update / star / unstar / reset-
protocol / delete, error-envelope probes, etc.). The tutorial is not
trying to walk those — `clier <command> --help` is the SSOT for
those, and free-form is exactly how they are validated. A clean
tutorial-path = both directions empty.

## 5. Publish

Write one `reports/qa-<run-id>.json`:

```jsonc
{
  "schema_version": 1,
  "id": "qa-<run-id>",
  "started_at": "...", "finished_at": "...",
  "os": "...", "clier_version": "...",
  "auth_target": "<your namespace>", "disposable_prefix": "qa-...-claude",
  "agent": { "kind": "claude" },
  "summary": "<one narrative paragraph of the verdict>",
  "findings": [ ...your findings ]
}
```

Then update `reports/index.json` — it is a JSON array of run summaries (newest first). Read the existing file (if any), prepend this run's entry, write back:

```json
[
  {
    "id": "qa-<run-id>",
    "clier_version": "...",
    "summary": "<one-line summary>",
    "verdict": "pass",
    "counts": { "total": N, "pass": ..., "fail": ..., "skip": ..., "error": ... }
  },
  ...older entries...
]
```

`verdict` is `pass` if there are no `fail` or `error` findings; otherwise `fail`. Counts come from `findings[].status`.

Self-validate before commit. The schema is `schema/report-v1.schema.json`; key invariants:

- `findings[].status == "fail"` → `fail_note` required (string).
- `findings[].status == "error"` → `error_detail` required.
- `findings[].status == "skip"` → `skip_reason` required.
- Every `pass` / `fail` / `error` finding must carry concrete evidence (`command` + `stdout_excerpt` / `stderr_excerpt` / `exit_code`, or `steps[]`, or `references[]`).

If your in-memory findings break any of those, fix them — drop the bare assertions, attach the missing evidence, or downgrade to `skip`. Do not publish a report that fails its own schema or violates the Evidence-first rule.

Finally:

```bash
git add reports/
git commit -m "qa: report qa-<run-id>"
git push
```
