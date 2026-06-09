---
name: looper-build
description: Fix bugs and implement features. Trigger when the user says "fix this bug" or "implement this feature."
---

Apply the research output. Smallest possible change. Quality gates before declaring done.

## Pre-build domain gates (NON-NEGOTIABLE)

Read the research report's "Pre-build gates required" section. For EACH gate, the looper agent (orchestrator) must invoke the subagent via Task tool BEFORE this skill writes code. If a gate hasn't been satisfied, STOP and tell the orchestrator to invoke it.

Common gates and what they produce:

| Touching | Gate | What it produces |
|---|---|---|
| Web UI (.tsx, .jsx, .html, .vue, templates) | `accessibility-agents:accessibility-lead` | ARIA contract, semantic-HTML requirements, focus-management plan |
| Color tokens, themes, contrast, CVD | `accessibility-agents:accessibility-lead` | Per-bundle contrast thresholds, CVD-safe palette guidance, exclusion lists |
| Auth, sessions, tokens, permissions | Security review (`the-diamantaire` with security framing) | Threat model, invariants to preserve |
| Database migration | Migration-safety review | Squawk-clean rules, lock-timeout pattern, NOT VALID + VALIDATE constraint pattern |

Do NOT bypass via Bash. Do NOT proceed without gate output in hand. The orchestrator is responsible for invoking; this skill enforces by refusing to proceed without it.

## Build procedure

1. Confirm research report received AND pre-build gate outputs received (where required). If missing, STOP — ask orchestrator to fill them.
2. If the project uses TDD (check CLAUDE.md), write failing tests FIRST.
3. Make the smallest code change that satisfies the spec. No bonus refactors, no unrelated cleanups, no defensive code for hypothetical futures. Three similar lines is better than a premature abstraction.
4. For new files: use `Write`. For modifications: use `Edit`. Do NOT use `cat > file` via Bash. Bash bypasses project write-gates that exist for review.
5. Run, in order: `format` → `lint` → `test` → `build`. All must pass before declaring done. If the project has a different sequence in CLAUDE.md or memory `feedback-build`, follow that.

## Quality bars

- No comments explaining WHAT — well-named identifiers carry that. Comments only for non-obvious WHY.
- No god files. Refactor when files cross the project's threshold (often 100 lines per CLAUDE.md).
- Follow project style: import order, naming conventions, class-ordering rules (e.g. Tailwind ordering in CLAUDE.md).
- No untrusted optimization. Chase only proven hot paths.
- Trust internal code. Only validate at system boundaries (user input, external APIs).
- No backwards-compatibility shims for code you're certain is unused — delete it.

## UI / accessibility specific

- Use semantic HTML before reaching for ARIA. ARIA is patching, not architecture.
- Drive styling off DOM attributes via framework variants (e.g. `aria-disabled:`, `data-state=`) — not JS ternaries that pick class strings. Locks visual + ARIA state at the cascade layer.
- For colors, use tokens from the gate output. Never eyeball contrast.
- For borders that convey meaning, contrast-check against BOTH the bundle bg AND any adjacent surface the border touches.

## Stop conditions

- Domain gate not satisfied → STOP, escalate to orchestrator
- Research report missing or ambiguous on a critical decision → STOP, ask
- Spec requires a breaking change to a public contract → STOP, surface to user
- Discovered scope is 2× or more than what research planned → STOP, ask about staging (per memory `feedback-refactor-staging`)
- Gate hook blocking Edit/Write → STOP, escalate. Never use Bash to bypass.

Smallest-blast-radius wins. If a fix CAN be 5 lines, do not make it 50.
