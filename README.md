# clier-qa

Black-box QA for the [clier](https://github.com/jakeraft/clier) CLI. Results are published as a data-driven site at https://jakeraft.github.io/clier-qa/.

## The lens

clier's primary consumer is an **AI agent**, not a human at a terminal. QA is framed accordingly: "what does an agent-as-consumer need to trust about a CLI tool?" rather than "does the UX feel nice".

We organise around seven trust points:

1. **Orient from nothing** — discover the core workflow from `--help` alone
2. **Canonical flow holds** — documented flows match actual behaviour
3. **Failure guides next action** — errors explain *and* suggest what to try next
4. **State is transparent** — every mutation is queryable via the CLI itself
5. **Output is parseable** — consistent JSON, `[]` not `null`, RFC3339 timestamps
6. **Mode sensitivity** — agent/user modes expose the right surface
7. **No leftover state** — disposable resources are removable on demand

## Report shape

One report = two flat sections.

- **A. Autonomous exploration** — findings only an agent-as-consumer can produce. Qualitative, `source: agent`.
- **B. Scripted scenarios** — deterministic CLI verifications. `setup → action → assertion → teardown`. Each scenario is a single self-contained shell script.

Findings in A that become reliably detectable migrate to B over time.

## Schema

`schema/report-v1.schema.json` defines the shape. Key primitives:

- `finding` — agent-authored judgement (exploration section)
- `scenario` — deterministic check (scripted section)
- `evidence.kind` — `command` | `scenario` | `observation`
- `status` — `pass` | `fail` | `skip` | `error`

Conditional requires (e.g. `status=fail` needs `fail_note`) are enforced by the schema.

## Pipeline

```
scripts/scenarios/*.sh           one scenario per file, emits one v1 fragment
      ↓
scripts/qa.sh                    iterates scenarios, collects fragments
      ↓
findings.json (optional)         agent-authored findings for section A
      ↓
scripts/lib/compose-report.py    merges, validates, writes reports/<id>.json
      ↓
git push                         GitHub Pages auto-rebuilds
      ↓
https://jakeraft.github.io/clier-qa/#/report/<id>
```

## Repo layout

```
clier-qa/
├── index.html                         SPA renderer (hash-routed)
├── style.css                          styles
├── schema/
│   └── report-v1.schema.json          source of truth
├── scripts/
│   ├── qa.sh                          driver: runs all scenarios + composes
│   ├── scenarios/                     one file per scenario
│   │   └── skill.create-and-delete.sh
│   └── lib/
│       ├── compose-report.py          merge + validate + write
│       └── validate-check.py          validate a fragment against the schema
├── reports/
│   ├── index.json                     list used by the SPA
│   └── <run-id>.json                  one report per run
└── README.md
```

## Running a sweep

Minimal — scripted only:

```bash
./scripts/qa.sh --summary "<one line>"
```

With agent-authored findings:

```bash
./scripts/qa.sh \
  --summary "<one line>" \
  --findings-file findings.json \
  --exploration-summary "<narrative paragraph>"
```

Then publish:

```bash
git add reports/
git commit -m "qa: report <run-id>"
git push
```

## Adding a scripted scenario

1. `cp scripts/scenarios/skill.create-and-delete.sh scripts/scenarios/<new>.sh`
2. Update `SCENARIO_ID`, `TITLE`, `PRECONDITION`, `EXPECTED`, and the step blocks
3. Verify standalone: `./scripts/scenarios/<new>.sh | python3 scripts/lib/validate-check.py`
4. Commit — `scripts/qa.sh` picks it up automatically

## Dependencies

- `clier` CLI on PATH
- `jq`
- `python3` + `jsonschema` + `referencing` (`pip3 install jsonschema referencing`)
- `bash`
- authenticated clier session (`clier auth login`)
