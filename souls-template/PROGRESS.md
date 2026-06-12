# SOUL Templates — Progress Manifest

Source SOULs live at `~/.hermes/PROJECTS/hermes-memory/souls/hm-*.md`.
Each template here mirrors one of those, with project-specific values
extracted into `{{ '{{' }} placeholders {{ '}}' }}`.

## Status

| Role | Template file | Status | Source lines | Template lines |
|---|---|---|---|---|
| auditor | `auditor.md.tmpl` | ✅ DONE | 52 | 68 |
| orchestrator | `orchestrator.md.tmpl` | ✅ DONE | 499 | 340 |
| planner | `planner.md.tmpl` | ✅ DONE | 361 | 370 |
| architect | `architect.md.tmpl` | ✅ DONE | 334 | 343 |
| developer | `developer.md.tmpl` | ✅ DONE | 386 | 370 |
| qa | `qa.md.tmpl` | ✅ DONE | 482 | 370 |
| docs | `docs.md.tmpl` | ✅ DONE | 317 | 316 |

## How to extract a new template

Given a source SOUL `~/.hermes/PROJECTS/hermes-memory/souls/hm-<role>.md`:

1. `cp <source> <role>.md.tmpl` (initial copy)
2. **Identity sweep:** replace `hm-<role>` → `{{ '{{' }} project.slug {{ '}}' }}-<role>`
   throughout the file. The role name is hardcoded; the slug is parameterized.
3. **Path sweep:** replace `~/.hermes/PROJECTS/hermes-memory/` →
   `~/.hermes/PROJECTS/{{ '{{' }} project.slug {{ '}}' }}/`
4. **Domain sweep:** identify references to project-specific concepts
   (hermes-memory uses: "memory", "redaction", "Qdrant", "holographic",
   "hermes-local"). For each:
   - If it's a label/name → parameterize via `project.name` / `project.domain`
   - If it's a guardrail → move to `guardrails.<role>` in `project.yaml`,
     render as a loop
   - If it's a path → parameterize via `paths.source_root` etc.
   - If it's a sibling project → render from `paths.sibling_projects` loop
5. **Test command sweep:** replace `bash scripts/run_tests.sh tests/integration/memory/`
   → `{{ '{{' }} project.test_command {{ '}}' }}`
6. **Phase count sweep:** replace `Phases 1 through 6` →
   `Phases 1 through {{ '{{' }} phases.count {{ '}}' }}`
7. **Escalation channel sweep:** replace `David` →
   `{{ '{{' }} escalation.contact {{ '}}' }}`, `telegram` →
   `{{ '{{' }} escalation.channel {{ '}}' }}`
8. **Validate** by rendering against `examples/hermes-memory.yaml` and
   diff'ing against the source SOUL. Only project-specific values should differ.

## Estimating effort

The five remaining templates total ~1,880 lines of source. Based on the
orchestrator template (499 source → 340 template lines, ~2 hours of focused
work with diff-driven validation), the remaining templates are roughly:

| Role | Est. effort | Approach |
|---|---|---|
| developer | ~1.5h | Most paths + guardrails; biggest payoff for reuse |
| qa | ~1.5h | Similar to developer; testing-focused guardrails |
| planner | ~1h | Already mostly generic; light extraction |
| architect | ~1h | Generic role; few project-specific refs |
| docs | ~0.5h | Smallest scope; mostly path substitution |

**Total:** ~5.5h to complete all five. Recommend doing developer + qa first
(largest impact for financial-app), then the rest in any order.

## Notes / pitfalls

- **Jinja2 syntax** is what we'll use for templating. The renderer
  (`scripts/render-soul.py`) MUST handle: simple substitution, `default()`
  filter, `length` filter, `trim` filter, `for` loops, `if/endif` blocks,
  and `join()` filter.
- **Whitespace:** Jinja2 strips by default; use `{{ '{%-' }}` / `{{ '-%}' }}` to
  trim. Test against current SOULs for byte-equivalence.
- **Don't over-parameterize.** A reference that's "always Plan.md" doesn't
  need to be `{{ '{{' }} inputs.plan_md {{ '}}' }}` — it can stay as a literal in
  the template. Only parameterize what would actually vary between projects.
- **Don't under-parameterize either.** Hermes-memory baked the word
  "redaction" into 14 places in `hm-developer.md`. That's project-specific
  vocabulary. Use the `guardrails.developer` list to inject those.
