# PROJECTS Framework

> **Pluggable kanban-orchestrated multi-agent development framework**.
>
> This directory holds the templates, schemas, and scripts that let any
> new project under `~/.hermes/PROJECTS/<slug>/` adopt the same
> orchestrator-driven multi-agent development workflow that hermes-memory
> uses, without copying-and-renaming files by hand.
>
> **Status: SCAFFOLDING — non-invasive, no existing project relies on this yet.**
> Tracking progress here will not disturb hermes-memory's running orchestrator.

---

## What problem this solves

The hermes-memory project demonstrated that a Ralph-loop orchestrator + a small
crew of specialist worker agents (planner, architect, developer, qa, docs,
auditor) can drive a real multi-week, multi-phase build to completion, with
human sign-off at phase gates and escalation when stuck.

The challenge: ~80 % of that machinery is generic, but the first version baked
project-specific names and domain knowledge directly into SOUL files,
hardcoded `hm-*` profile names, and a single cron job. That works for one
project but doesn't scale.

This framework extracts the generic parts into templates and a single
`project.yaml` so any new project can be bootstrapped in minutes:

```bash
mkdir -p ~/.hermes/PROJECTS/financial-app
cd ~/.hermes/PROJECTS/financial-app
# Author PROJECT.md, prd.md, TDD.md, Plan.md, EPICS.md (the inputs)
# Write project.yaml (the framework config)
hermes_kanban_bootstrap ./project.yaml
# 7 profiles created, SOULs installed, cron registered, orchestrator IDLE → ready
```

## Architecture

Three layers, increasing in specificity:

```
┌──────────────────────────────────────────────────────────────────┐
│ LAYER 1 — FRAMEWORK (this directory)                             │
│   • souls-template/<role>.md.tmpl      generic SOUL prose        │
│   • heartbeat.sh.tmpl                  generic cron driver       │
│   • install-souls.sh                   generic profile installer │
│   • bootstrap.sh                       one-shot project setup    │
│   • schema/project.schema.yaml         project.yaml validator    │
│   • examples/hermes-memory.yaml        reference project.yaml    │
└──────────────────────────────────────────────────────────────────┘
                              │
                              │ rendered + installed into
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ LAYER 2 — PROJECT SCAFFOLD (per project, ~/.hermes/PROJECTS/X/)  │
│   • project.yaml          ← human-edited config                  │
│   • PROJECT.md, prd.md, TDD.md, Plan.md, EPICS.md  (inputs)      │
│   • orchestrator/{GOAL,STATE,HISTORY}.md  (rendered + live)      │
│   • souls/<slug>-<role>.md  (rendered from template + yaml)      │
│   • scripts/heartbeat.sh  (thin shim invoking framework version) │
│   • scripts/install-souls.sh  (thin shim)                        │
└──────────────────────────────────────────────────────────────────┘
                              │
                              │ installed by install-souls.sh into
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ LAYER 3 — RUNTIME (per-role Hermes profiles, ~/.hermes/profiles/)│
│   ~/.hermes/profiles/<slug>-orchestrator/SOUL.md                 │
│   ~/.hermes/profiles/<slug>-planner/SOUL.md                      │
│   ~/.hermes/profiles/<slug>-architect/SOUL.md                    │
│   ~/.hermes/profiles/<slug>-developer/SOUL.md                    │
│   ~/.hermes/profiles/<slug>-qa/SOUL.md                           │
│   ~/.hermes/profiles/<slug>-docs/SOUL.md                         │
│   ~/.hermes/profiles/<slug>-auditor/SOUL.md                      │
└──────────────────────────────────────────────────────────────────┘
```

## Why slug-prefixed profile names matter

The original hermes-memory used `hm-orchestrator`, `hm-developer`, etc. That
works for one project but collides the moment we add a second one. The
framework requires every project to choose a unique short `slug` and prefixes
every profile name, kanban tenant, cron job name, and rendered SOUL with it.

Examples of good slugs:

| Project | Slug | Profile names |
|---|---|---|
| Hermes Memory | `hm` | `hm-orchestrator`, `hm-developer`, ... |
| Financial App | `fin` | `fin-orchestrator`, `fin-developer`, ... |
| OpenClaw v2 | `ocw` | `ocw-orchestrator`, `ocw-developer`, ... |

Two- or three-letter slugs work best — they keep profile and kanban tenant
names readable without being so terse they collide with built-in Hermes
profiles (`default`, etc.).

## What's in `project.yaml`

The single source of truth for everything project-specific. See
`schema/project.schema.yaml` for the full validated schema and
`examples/hermes-memory.yaml` for a fully-populated reference. The high-level
sections are:

- **`project`** — slug, name, domain, source roots, test/build commands
- **`phases`** — phase count, acceptance-test section reference
- **`goal`** — headline, out-of-scope items, hard constraints (rendered into GOAL.md)
- **`escalation`** — where the orchestrator pings the human (telegram, discord, none)
- **`orchestrator`** — cron schedule, cooldown, max actions/tick
- **`models`** — per-role provider + model
- **`skills`** — per-role skill packages to load
- **`paths`** — project-specific code paths the developer/qa SOULs need to know
- **`guardrails`** — project-specific "NEVER" rules baked into developer/qa SOULs

## Workflow for adopting on a new project

1. Create `~/.hermes/PROJECTS/<slug>/` and author the human inputs:
   PROJECT.md, prd.md, TDD.md, Plan.md, EPICS.md, optionally TASKLIST.md
2. Copy `examples/hermes-memory.yaml` → `<slug>/project.yaml`, edit values
3. Pre-Sprint-1 ADRs (if any) — author them under `docs/adr/`
4. Run `bootstrap.sh <slug>/project.yaml`
   - Validates yaml against schema
   - Renders all 7 SOULs to `<slug>/souls/`
   - Creates `orchestrator/{GOAL,STATE,HISTORY}.md`
   - Creates 7 Hermes profiles
   - Symlinks heartbeat.sh + install-souls.sh shims into `<slug>/scripts/`
   - Runs install-souls.sh to push SOULs into profile homes
   - Registers the cron job
   - Prints next-action checklist
5. Verify orchestrator picks up with `hermes cron run <slug>-orchestrator`

## Migrating an existing project

For hermes-memory specifically: the framework will be deliberately built so
that running `bootstrap.sh` against a populated `hermes-memory/project.yaml`
re-renders SOULs that are byte-identical (modulo whitespace) to the
hand-written ones today. That's our regression test for the templates.

The migration plan once Phase 6 of hermes-memory completes:
1. Write `hermes-memory/project.yaml` (this directory has the example)
2. Run bootstrap with `--check` mode → diff rendered SOULs vs hand-written ones
3. Reconcile diffs by either updating templates (if the hand-written version
   is the right pattern) or updating SOULs (if the template caught a drift)
4. Switch the cron job to invoke framework heartbeat.sh
5. Decommission `hermes-memory/scripts/orchestrator-heartbeat.sh` (replace
   with a thin shim)

This work is intentionally deferred until hermes-memory Phase 6 closes.

## Non-goals

- Replacing Mission Control / Hermes Kanban — this framework rides on top of
  the existing kanban backend, it does not replace it.
- Automating PRD/TDD/Plan authorship — those remain human-authored inputs.
- Cross-project work coordination — each project is independent. Project A's
  orchestrator never talks to Project B's. If you need that, build a meta-
  orchestrator above this layer (out of scope).

## Directory layout (planned)

```
.framework/
├── README.md                              # this file
├── schema/
│   └── project.schema.yaml                # JSON-Schema for project.yaml validation
├── souls-template/
│   ├── orchestrator.md.tmpl
│   ├── planner.md.tmpl
│   ├── architect.md.tmpl
│   ├── developer.md.tmpl
│   ├── qa.md.tmpl
│   ├── docs.md.tmpl
│   └── auditor.md.tmpl
├── scripts/
│   ├── bootstrap.sh                       # one-shot project init
│   ├── heartbeat.sh                       # generic cron driver
│   ├── install-souls.sh                   # generic profile sync
│   └── render-soul.py                     # Jinja-style template renderer
├── examples/
│   ├── hermes-memory.yaml                 # reference, drives regression test
│   └── financial-app.yaml                 # starter for upcoming project
└── docs/
    ├── ARCHITECTURE.md                    # deeper design discussion
    ├── ROLES.md                           # what each role does, escalation rules
    └── MIGRATION.md                       # how to retrofit existing project
```

## Where this code lives

This framework is intentionally NOT inside `hermes-agent/` core — it's a
*project-pattern*, not a Hermes feature. It lives under `~/.hermes/PROJECTS/`
because that's the natural home for project-pattern conventions.

The reusable parts (the `kanban-project-bootstrap` skill, generic kanban
worker pitfalls) live in `~/.hermes/skills/` and are loaded by the SOULs at
runtime. The skills are the public API.

---

**Status:** Scaffolding in progress, 2026-05-21. See git history under
`infra/projects-framework/` in the openclaw-workspace repo for changes.
