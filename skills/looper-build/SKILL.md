---
name: looper-build
description: Fix bugs and implement features. Trigger when the user says "fix this bug" or "implement this feature."
---

Apply research output. Smallest change possible. Quality gates before done.

## Pre-build domain gates (NON-NEGOTIABLE)

Read research report "Pre-build gates required" section. For EACH gate, looper agent (orchestrator) must invoke subagent via Task tool BEFORE this skill write code. Gate not satisfied? STOP, tell orchestrator invoke it.

Common gates and output:

| Touching                                    | Gate                                                      | What it produces                                                                  |
| ------------------------------------------- | --------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Web UI (.tsx, .jsx, .html, .vue, templates) | `accessibility-agents:accessibility-lead`                 | ARIA contract, semantic-HTML requirements, focus-management plan                  |
| Color tokens, themes, contrast, CVD         | `accessibility-agents:accessibility-lead`                 | Per-bundle contrast thresholds, CVD-safe palette guidance, exclusion lists        |
| Auth, sessions, tokens, permissions         | Security review (`the-diamantaire` with security framing) | Threat model, invariants to preserve                                              |
| Database migration                          | Migration-safety review                                   | Squawk-clean rules, lock-timeout pattern, NOT VALID + VALIDATE constraint pattern |

No bypass via Bash. No proceed without gate output in hand. Orchestrator invoke; this skill enforce by refusing proceed without it.

## Build procedure

1. Confirm research report received AND pre-build gate outputs received (where required). Missing? STOP — ask orchestrator fill them.
2. Project use TDD (check CLAUDE.md)? Write failing tests FIRST.
3. Smallest code change that satisfy spec. No bonus refactors, no unrelated cleanups, no defensive code for hypothetical futures. Three similar lines better than premature abstraction.
4. New files: use `Write`. Modifications: use `Edit`. Do NOT use `cat > file` via Bash. Bash bypass project write-gates that exist for review.
5. Run, in order: `format` → `lint` → `test` → `build`. All must pass before done. Project has different sequence in CLAUDE.md or memory `feedback-build`? Follow that.

## Quality bars

- No comments explain WHAT — well-named identifiers carry that. Comments only for non-obvious WHY.
- No god files. Refactor when files cross project threshold (often 100 lines per CLAUDE.md).
- Follow project style: import order, naming conventions, class-ordering rules (e.g. Tailwind ordering in CLAUDE.md).
- No untrusted optimization. Chase only proven hot paths.
- Trust internal code. Validate only at system boundaries (user input, external APIs).
- No backwards-compat shims for code certain unused — delete it.

## UI / accessibility specific

- Use semantic HTML before reach for ARIA. ARIA patch, not architecture.
- Drive styling off DOM attributes via framework variants (e.g. `aria-disabled:`, `data-state=`) — not JS ternaries pick class strings. Locks visual + ARIA state at cascade layer.
- Colors: use tokens from gate output. Never eyeball contrast.
- Borders convey meaning: contrast-check against BOTH bundle bg AND any adjacent surface border touches.

## Stop conditions

- Domain gate not satisfied → STOP, escalate to orchestrator
- Research report missing or ambiguous on critical decision → STOP, ask
- Spec require breaking change to public contract → STOP, surface to user
- Discovered scope 2× or more than research planned → STOP, ask about staging (per memory `feedback-refactor-staging`)
- Gate hook blocking Edit/Write → STOP, escalate. Never use Bash bypass.

Smallest-blast-radius win. Fix CAN be 5 lines? No make 50.
