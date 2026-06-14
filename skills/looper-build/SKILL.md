---
name: looper-build
description: Fix bugs and implement features. Trigger when the user says "fix this bug" or "implement this feature."
---

Apply research output. Smallest change. Quality gates before done.

## Pre-build inputs (NON-NEGOTIABLE)

Build proceed when `looper-plan` brief in hand. Plan absorb deterministic portion of pre-build domain gates (mechanized contract tests, Squawk dry-run, caller-graph grep, baseline measurement). Build consume plan brief direct.

Two cases for specialist gate output:

| Case                               | Build behavior                                                                                           |
| ---------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Plan completed clean (no ESCALATE) | Proceed. Plan mechanized predictions cover deterministic surface; no specialist needed.                  |
| Plan emitted ESCALATE              | Brief MUST include `gate outputs` from specialist (orchestrator pre-flighted). Missing = STOP, escalate. |

Specialist gates relevant when plan ESCALATE (orchestrator job, not build):

| Touching                                                         | Gate                                                      | What it produces                                                           |
| ---------------------------------------------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------- |
| Web UI (novel palette, brand-locked, rendering-context judgment) | `accessibility-agents:accessibility-lead`                 | ARIA contract, semantic-HTML requirements, focus-management plan           |
| Color tokens (all recovery options exhausted)                    | `accessibility-agents:accessibility-lead`                 | Per-bundle contrast thresholds, CVD-safe palette guidance, exclusion lists |
| Auth, sessions, tokens, permissions (threat model judgment)      | Security review (`the-diamantaire` with security framing) | Threat model, invariants to preserve                                       |
| Database migration (concurrent-write semantics)                  | Migration-safety review                                   | Lock-timeout pattern, NOT VALID + VALIDATE constraint pattern              |

No bypass via Bash. Plan ESCALATE without orchestrator-fired specialist → STOP, escalate. Skill enforce by refuse proceed without `gate outputs` populated when plan brief flag escalation.

## Build procedure

1. Confirm `looper-plan` brief in hand. If brief flagged ESCALATE, confirm `gate outputs` populated from orchestrator-fired specialist. Missing either → STOP, ask orchestrator fill them.
2. Determine wave kind from brief:
   - **Code wave** (source files touched) → steps 4–6 below
   - **Non-code wave** (PR body, GitHub release, external config, docs-only) → step 7 below
3. **Confirm rung from brief.** Plan stated rung 1-5 → proceed. Rung 6 (custom) without named justification (perf/a11y/security/data-loss/trust-boundary or cited requirement) → STOP, send back to plan. Bias toward lower rung holds during build too: implementing reveal lower rung satisfy requirement → take it, note downgrade.
4. Project use TDD (check CLAUDE.md)? Write failing tests FIRST.
5. Smallest code change satisfy spec. No bonus refactors, no unrelated cleanups, no defensive code for hypothetical futures. Three similar lines beat premature abstraction.
6. New files: use `Write`. Modifications: use `Edit`. Do NOT use `cat > file` via Bash. Bash bypass project write-gates that exist for review. Then run, in order: `format` → `lint` → `test` → `build`. All must pass before done. Project has different sequence in CLAUDE.md or memory `feedback-build`? Follow that.
7. **Non-code wave path**:
   - PR body / GitHub release: use `gh pr edit <N> --body` / `gh release edit` via Bash. No format/lint/test/build (no source touched). Verify via `gh pr view` / `gh release view` next step.
   - External config (CI yaml, eslintrc, package.json metadata): use `Edit`. Run config-specific validator only (`gh workflow run --dry`, `eslint --print-config`, `npm pkg fix`). Skip framework-wide format/lint/test/build unless config affect them.
   - Docs-only (.md, README, THEMES.md, ARCHITECTURE.md): use `Edit`. Run `npm run format` + project markdown linter (markdownlint, vale) if present. Skip test/build (no source compiled).

## Quality bars

- No comments explain WHAT — well-named identifiers carry that. Comments only for non-obvious WHY.
- No god files. Refactor when files cross project threshold (often 100 lines per CLAUDE.md).
- Follow project style: import order, naming conventions, class-ordering rules (e.g. Tailwind ordering in CLAUDE.md).
- No untrusted optimization. Chase only proven hot paths.
- Trust internal code. Validate only at system boundaries (user input, external APIs).
- No backwards-compat shims for code certain unused — delete.

## UI / accessibility specific

- Use semantic HTML before reach for ARIA. ARIA patch, not architecture.
- Drive styling off DOM attributes via framework variants (e.g. `aria-disabled:`, `data-state=`) — not JS ternaries pick class strings. Lock visual + ARIA state at cascade layer.
- Colors: use tokens from gate output. Never eyeball contrast.
- Borders convey meaning: contrast-check against BOTH bundle bg AND any adjacent surface border touches.

## Stop conditions

- Domain gate not satisfied → STOP, escalate to orchestrator
- Research report missing or ambiguous on critical decision → STOP, ask
- Spec require breaking change to public contract → STOP, surface to user
- Discovered scope 2× or more than research planned → STOP, ask about staging (per memory `feedback-refactor-staging`)
- Gate hook blocking Edit/Write → STOP, escalate. Never use Bash bypass.

Smallest-blast-radius win. Fix CAN be 5 lines? No make 50.