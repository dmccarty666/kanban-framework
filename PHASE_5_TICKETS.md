# Phase 5 — Framework Bug Batch (filed 2026-06-13)

These are 3 real framework bugs surfaced during the dummy end-to-end retest on 2026-06-13. None block current work (T-006 was marked done manually, the dummy orchestrator cron has been re-enabled, and the AIMASTER watchdog is in place to catch future issues). All three are recommended for Phase 5.

---

## BUG-1: Truncation safety net missing in worker runtime

**Severity:** High (causes phantom protocol violations, wastes failure_limit retries)

**Surface:** Every model with a token wall, on every card where the worker's response approaches max output tokens.

**Observed:** 2026-06-13 01:38-01:40 UTC on T-006 (t_9e0ed36b) on AIDEV. Worker hit `finish_reason='length'`, retry policy exhausted (3/3), framework bailed with rc=0, never invoked `kanban_block` or `kanban_complete`. CSS work was actually complete on disk but the card was marked blocked.

**Root cause:** The truncation-retry-exhausted branch has no safety net to auto-invoke `kanban_block(reason='output-truncated')` before exiting.

**Suggested fix:** In the runtime's truncation-retry-exhausted branch:
- Emit a `kanban_block` call (or kanban-comment) with reason `output-truncated: <last step description>`
- Exit with non-zero rc (so the failure is visible to cron, supervisor, etc.)
- Log a structured event so post-mortem tools can find it

**Scope:** Hermes core agent loop, not kanban-framework. The orchestrator SOUL should note this crash mode.

**Effort estimate:** 2-4 hours (find the right code path, add the safety net, add tests for both truncation-recovered and truncation-exhausted paths).

---

## BUG-2: SOUL scope mismatch — XS cards shouldn't do full TDD

**Severity:** Medium (wastes tokens, increases crash probability on small cards)

**Surface:** Every Size XS card dispatched to a worker that interprets "Pre-complete pattern" as "must write full test suite."

**Observed:** 2026-06-13 01:36-01:40 UTC on T-006 (Size XS, "Form CSS additions") — worker tried to write an 87-line pytest suite of regex-based CSS assertions. Hit token limit twice.

**Root cause:** The orchestrator SOUL's §"Pre-complete pattern" guidance was written for Size M+ tasks. XS cards get the same instructions, which is overkill for the work scope and pushes responses past token limits.

**Suggested fix:** In `/disk2/dmccarty/PROJECTS/kanban-framework/souls-template/orchestrator.md.tmpl`:
- Add a §"Card sizing guidance" section that explicitly says:
  - **XS:** Single `patch` or small `write_file` + 0-1 smoke tests
  - **S:** Single feature implementation + 1-3 focused tests
  - **M:** Multi-file feature + full TDD coverage
  - **L/M+:** Decompose further; never dispatch L+ as a single card
- Cross-reference the size in the card body so the worker knows what to expect

**Scope:** kanban-framework orchestrator SOUL template only.

**Effort estimate:** 1-2 hours (add the section, render against dummy, verify behavior).

---

## BUG-3: Stale orchestrator lock file (heartbeat.sh)

**Severity:** Low (cosmetic, but masks real state)

**Surface:** Any project orchestrator that runs for a long time without clean EXIT (OOM, signal, terminal disconnect).

**Observed:** 2026-06-13 — dummy project's `/disk2/dmccarty/PROJECTS/dummy/orchestrator/.lock` was ~5h stale. Orchestrator correctly refused to touch it per SOUL contract. Tick 35+ had to record the lock staleness in every STATE.md update.

**Root cause:** heartbeat.sh's EXIT trap should clean the lock on script exit, but something is preventing it from firing reliably.

**Suggested fix:** Two-pronged:
- **Investigate why EXIT trap isn't firing** (signal? early-exit path? nested subshell?)
- **Add a guaranteed `rm -f $LOCKFILE` at the start of each tick** (idempotent — the file is only locked by the running tick itself, which will be a different PID by then). The existing EXIT trap stays as belt-and-suspenders.
- Add a debug log line: `[heartbeat] lock state at start: $(ls -la $LOCKFILE 2>&1)`

**Scope:** `/disk2/dmccarty/PROJECTS/kanban-framework/scripts/heartbeat.sh` (template) + all rendered copies.

**Effort estimate:** 1 hour.

---

## Notes for Phase 5 planning

- All 3 bugs are independent — can be tackled in any order
- BUG-1 is the highest-leverage fix (every model with a token wall produces these phantom violations)
- BUG-2 should land before any more XS cards are dispatched
- BUG-3 can wait; current workaround (record staleness in STATE.md) is acceptable
