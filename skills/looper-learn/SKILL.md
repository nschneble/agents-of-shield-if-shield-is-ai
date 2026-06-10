---
name: looper-learn
description: Learn from your experiences. Trigger when the user says "reflect on this" or "remember what we just did here."
---

Suite of looper skills ran. Determine how went, capture reusable lessons.

## Diagnosis checklist

For each step in loop, ask:

1. **research** — Surface right constraints (WCAG SC + thresholds, security invariants, perf budgets)? Challenge scope correctly? Plan/build re-discover things mid-flight?
2. **plan** — Mechanized predictions ran or fall-through honest? Recovery options pre-staged? Risk register caught what review later surfaced? Plan emit ESCALATE when needed, or substitute judgment silently?
3. **build** — Plan brief consumed direct or re-derived? Change scope creep beyond plan? Bash bypass guards? Quality bars (no Bash writes, no scope creep, no premature abstraction) honored? Non-code wave path chosen correctly when applicable?
4. **verify** — Verify catch bugs verify should catch? Or review catch things verify missed? (If yes, verify checklist too thin.) Doc/PR-body/config waves verified by reading resource back, not skipped?
5. **review** — How many review iterations? Specialists recommended for crew pass when domain expertise mattered? Review surface blockers that should pre-flight in research/plan?
6. **commit** — Pre-flight gates honored? Commit landed for code/doc waves, skipped cleanly for external-state waves? PR detection correct (existing → just commit; none → draft created)?

## Save lessons at the right level

Match lesson to right persistence layer:

| Level                          | When to use                                                                            | Example                                                                     |
| ------------------------------ | -------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| **Memory** (per project)       | One-off project facts, user feedback patterns, surprising project-specific gotchas     | "Tuffgal stories must use real user actions, not engineer behaviors"        |
| **CLAUDE.md** (per project)    | Conventions, standing rules, hard constraints project enforces                         | "Migrations must pass Squawk; start with lock_timeout = '1s'"               |
| **Skill body** (cross-project) | Patterns apply to ALL projects looper runs in                                          | "For color work, pull WCAG thresholds in research before plan picks values" |
| **Agent body** (cross-project) | Orchestration patterns, subagent invocation rules                                      | "Web UI requires plan ESCALATE → a11y-lead gate"                            |
| **Loop de Looper body**        | Multi-wave orchestration patterns (crew cadence, queue management, escalation routing) | "For token-retirement waves, plan must run multi-extension orphan grep"     |

Skill caused failure (missing checklist item, vague advice, blind spot) → propose edit to skill body. Don't leave just memory. Memories = evidence; skill edits = fixes.

## What NOT to save

- Code patterns derivable from current code (`git blame` or `grep` find them)
- Fix recipes (commit / PR carry that)
- Ephemeral task details
- Anything already in CLAUDE.md or existing memory — update instead of duplicate

## Output

- List of new/updated memory files (with paths)
- List of CLAUDE.md edits (with paths)
- List of skill or agent edits (with paths)
- One-paragraph "what this means for next run" — concrete, not vibes

## Honest self-assessment

Step repeatedly fails same way across multiple loops → skill needs editing, not another memory. Agent orchestration logic the issue → propose agent edit. Failure environmental (missing tool, missing access) → say plain, don't paper over.

Looper improves only when learn brutally honest about what went wrong.
