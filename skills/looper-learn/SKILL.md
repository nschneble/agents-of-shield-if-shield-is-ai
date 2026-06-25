---
name: looper-learn
description: Learn from your experiences. Runs at two altitudes — per-wave (inside the-looper) and run-level (orchestration mode, at the end of Loop de Looper, diagnosing sizing/scope/crew cadence). Trigger when the user says "reflect on this" or "remember what we just did here."
---

Suite of looper skills ran. Determine how went, capture reusable lessons.

## Two altitudes

Learn runs at two altitudes, depending on who invokes it:

- **Wave mode** — invoked by `the-looper` as step 6, ONCE per wave. Diagnoses the seven steps of that one wave. The per-wave checklist below.
- **Run mode** — invoked by `loop-de-looper` ONCE at termination, after the final crew pass and before `looper-recap`. Diagnoses the *orchestration* across the whole run — sizing, scope, crew cadence, escalation routing — not any single wave. The run-level checklist below.

A wave can go perfectly while the orchestration around it was wrong (queue mis-sized, crew fired too late, a `full` run that was really one wave). Wave mode never catches that — it can't see past its own wave. Run mode exists for exactly that blind spot. Both modes feed the same save-level table and the same honesty rule.

## Per-wave diagnosis (wave mode)

For each step in the wave's loop, ask:

1. **research**: Surface right constraints (WCAG SC + thresholds, security invariants, perf budgets)? Challenge scope correctly? Plan/build re-discover things mid-flight?
2. **plan**: Mechanized predictions ran or fall-through honest? Recovery options pre-staged? Risk register caught what review later surfaced? Plan emit ESCALATE when needed, or substitute judgment silently?
3. **build**: Plan brief consumed direct or re-derived? Change scope creep beyond plan? Bash bypass guards? Quality bars (no Bash writes, no scope creep, no premature abstraction) honored? Non-code wave path chosen correctly when applicable?
4. **verify**: Verify catch bugs verify should catch? Or review catch things verify missed? (If yes, verify checklist too thin.) Doc/PR-body/config waves verified by reading resource back, not skipped?
5. **review**: How many review iterations? Specialists recommended for crew pass when domain expertise mattered? Review surface blockers that should pre-flight in research/plan?
6. **commit**: Pre-flight gates honored? Commit landed for code/doc waves, skipped cleanly for external-state waves? PR detection correct (existing → just commit; none → draft created)?

## Run-level diagnosis (orchestration mode)

Invoked by `loop-de-looper` at termination. Read the run's real trail — `local/loops/<branch>/gates.jsonl`, `git log --oneline main..HEAD`, the wave queue scope emitted, the nonbeliever verdict + sizing — and ask about the ORCHESTRATION, not any one wave:

1. **sizing**: Did nonbeliever size the goal right *in hindsight*? A `full-orchestration` run that collapsed to one real wave was over-sized; a `single-wave` that ballooned into a corrective queue was under-sized. Either is a nonbeliever-skill lesson, not a wave lesson.
2. **scope**: Did the queue hold, or did a wave turn out to depend on a later one (dependency order wrong)? Were waves the right grain — any that should have split, or merged? Did the run need a mid-flight re-scope (sign scope mis-decomposed up front)? Pilot-first honored for cross-cutting?
3. **crew cadence**: Did crew passes fire at the right drift? Too often (parallel passes burned on near-empty diffs) or too late (a blocker surfaced large that an earlier pass would have caught small)? Were the `waves=4 / files=30` triggers right for THIS domain, or should CLAUDE.md carry an override?
4. **escalation routing**: Did specialist gates fire when plan emitted ESCALATE, and clear in one round? Any thrash — same gate requested twice, which should have gone to the user sooner? Was Task-tool unavailability logged honestly (`ran: false`), never invented?
5. **PR + termination**: PR created early (wave 1) or orphaned to "the end"? Did termination fire at the right point — section 5 (required-not-loopable) surfaced explicitly, not silently skipped? Gate artifacts complete on disk, or did a narrated gate never hit `gates.jsonl`?
6. **state durability**: Did in-context queue/counters survive the run, or did a compaction lose them and force a git-log re-derive? Recurring loss is a persistence-layer lesson (the v2 state-JSON), not a one-off.

A finding here lands in the **Loop de Looper body** or **Agent body** row of the table below — orchestration patterns, not project facts. If the same orchestration step misfires across multiple runs, that is a skill edit, not another memory.

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
- Anything already in CLAUDE.md or existing memory: update instead of duplicate

## Output

- List of new/updated memory files (with paths)
- List of CLAUDE.md edits (with paths)
- List of skill or agent edits (with paths)
- One-paragraph "what this means for next run", concrete, not vibes

## Honest self-assessment

Step repeatedly fails same way across multiple loops → skill needs editing, not another memory. Agent orchestration logic the issue → propose agent edit. Failure environmental (missing tool, missing access) → say plain, don't paper over.

Looper improves only when learn brutally honest about what went wrong.
