# clier-qa

Black-box QA for the [clier](https://github.com/jakeraft/clier) CLI. Results are published at https://jakeraft.github.io/clier-qa/.

## The lens

clier's primary consumer is an **AI agent**, not a human at a terminal. QA is framed accordingly: "what does an agent-as-consumer need to trust about a CLI tool?"

We organise around six trust points:

1. **Orient from nothing** — discover the core workflow from `--help` alone
2. **Canonical flow holds** — documented flows match actual behaviour
3. **Failure guides next action** — errors explain *and* suggest what to try next
4. **State is transparent** — every mutation is queryable via the CLI itself
5. **Output is parseable** — consistent JSON, `[]` not `null`, RFC3339 timestamps
6. **No leftover state** — disposable resources are removable on demand

## Process

A QA run is performed entirely by an agent (see `qa-profile` / `qa-checklist` skills mounted in the `clier-qa-claude` team). The agent explores the CLI, records findings, writes one JSON report conforming to the schema, and commits + pushes it. No scripts, no fixtures. The agent's judgement is the test.

## Report shape

One report = flat metadata + narrative summary + a flat list of findings.

`schema/report-v1.schema.json` is the source of truth. Key bits:

- `id`, `started_at`, `finished_at`, `clier_version`, `os`, `auth_target`, `disposable_prefix`, `agent` — run metadata
- `summary` — one narrative paragraph
- `findings[]` — each finding has `id`, `title`, `status` (`pass`/`fail`/`skip`/`error`), `rationale`, and optional evidence fields (`command`, `exit_code`, `stdout_excerpt`, `stderr_excerpt`, `duration_ms`, `steps[]`, `references[]`)

Conditional requires (e.g. `status=fail` needs `fail_note`) are enforced by the schema.

## Repo layout

```
clier-qa/
├── index.html                         SPA renderer (hash-routed)
├── style.css
├── schema/
│   └── report-v1.schema.json          source of truth
├── reports/
│   ├── index.json                     list used by the SPA
│   └── <run-id>.json                  one report per run
└── README.md
```

## Publishing a run

The agent writes `reports/<run-id>.json` and updates `reports/index.json`, then:

```bash
git add reports/
git commit -m "qa: report <run-id>"
git push
```

GitHub Pages rebuilds in ~30s.

## `reports/index.json` shape

A flat array, newest first:

```json
[
  {
    "id": "2026-04-18T160000",
    "clier_version": "dev",
    "summary": "...",
    "verdict": "pass",
    "counts": { "total": 12, "pass": 11, "fail": 0, "skip": 1, "error": 0 }
  }
]
```
