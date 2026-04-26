---
name: qa-checklist
description: Use whenever you receive a QA request for the clier CLI. Full autonomous flow — set up, explore, publish one JSON report.
---

# QA Checklist

You are in the clier-qa working copy. `clier` is on PATH and authenticated. Run end-to-end without asking the user anything.

## 1. Set up

1. `clier --version`, `clier auth status` — confirm both. If either fails, add a `setup.*` finding with `status: error` and continue.
2. Pick a disposable prefix: `qa-$(date +%Y%m%d%H%M%S)`. Every resource you create uses it.
3. Capture run metadata you will need later: `started_at` (ISO 8601 UTC), `os` (`uname -sr`), `clier_version`, `auth_target`.

## 2. Explore

Walk the CLI comprehensively, judging against the six trust points in the qa-profile instruction. Treat the list below as **minimum probing dimensions**, not a script — inside each area, probe as far as your judgement suggests.

- **Every command** — run `--help` on every top-level command and every subcommand. Exercise the happy path of each.
- **Resource lifecycle (CRUD)** — for every mutable kind (team, skill, instruction, claude-settings, codex-settings), complete the full create → get → edit → delete cycle. Leave nothing behind.
- **Versioning** — fork, push-bump, pull, `@version` pinning, version queries. Probe: forking a specific version, forking a fork, edit → push → verify bump, pulling into a stale clone, referencing a non-existent version.
- **Working copy ↔ server consistency** — every way the two can diverge and how the CLI reconciles them. Probe: clone then server-side edit/delete, clone then local edit then push, race-like scenarios within a single agent, `status`/`fetch`/`pull`/`push` semantics, dirty-workspace behaviours.
- **Ref / dependency graph** — teams referencing skills/instructions/settings, version-pinned refs, ref target deletion, team composition (children).
- **Run lifecycle** — `run start` / `stop` / `attach` / `tell` / `view` / `list` / `note`. Probe single runs, interacting with the same workspace twice, and cross-workspace runs.
- **Deliberate failures** — across every area above, trigger failures to evaluate error quality (wrong args, missing refs, dirty workspace, duplicate start, destructive ops on guarded resources).

Build the `findings` array in memory as you go. Each finding:

```json
{
  "id": "crud.skill-lifecycle",
  "title": "Skill create → get → edit → delete leaves no residue",
  "status": "pass",
  "rationale": "Ran each step; final `clier list --owner <prefix>/*` returned [].",
  "command": "clier create skill --name ...",
  "exit_code": 0,
  "stdout_excerpt": "...",
  "duration_ms": 1234,
  "steps": [
    { "label": "create", "command": "clier create skill --name ...", "exit_code": 0, "status": "pass" },
    ...
  ],
  "references": [
    { "kind": "help_output", "label": "clier --help", "excerpt": "..." }
  ]
}
```

All fields beyond `id`, `title`, `status`, `rationale` are optional — include whichever actually carry evidence for that finding. Add `fail_note` / `skip_reason` / `error_detail` when status is `fail` / `skip` / `error`.

## 3. Publish

Write one `reports/<run-id>.json` conforming to `schema/report-v1.schema.json`:

```jsonc
{
  "schema_version": 1,
  "id": "<run-id>",
  "started_at": "...", "finished_at": "...",
  "os": "...", "clier_version": "...",
  "auth_target": "@clier", "disposable_prefix": "qa-...",
  "agent": { "kind": "claude" },
  "summary": "<one narrative paragraph>",
  "findings": [ ... ]
}
```

Then prepend a new entry to `reports/index.json` (a flat array, newest first):

```json
{
  "id": "<run-id>",
  "clier_version": "...",
  "summary": "<one-line summary>",
  "verdict": "pass",
  "counts": { "total": N, "pass": ..., "fail": ..., "skip": ..., "error": ... }
}
```

`verdict` is `pass` if no `fail` and no `error`; otherwise `fail`. Counts come from `findings[].status`.

Finally:

```bash
git add reports/
git commit -m "qa: report <run-id>"
git push
```

Publish regardless of outcome. A failing report is still a report.