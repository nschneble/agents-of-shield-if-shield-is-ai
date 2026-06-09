---
name: looper-learn
description: Learn from your experiences. Trigger when the user says "reflect on this" or "remember what we just did here."
---

A suite of looper skills just ran. Determine how it went and capture reusable lessons.

## Diagnosis checklist

For each step in the loop, ask:

1. **research** — Did it surface the right constraints (WCAG SC + thresholds, security invariants, perf budgets)? Did it challenge scope correctly? Did build have to go re-discover things mid-flight?
2. **build** — Did pre-build domain gates get invoked? Did the change scope creep beyond what research planned? Did Bash bypass any guards? Were quality bars (no Bash writes, no scope creep, no premature abstraction) honored?
3. **verify** — Did verify catch the bugs verify should have caught? Or did review catch things verify missed? (If yes, verify's checklist is too thin.)
4. **review** — How many review iterations? Were specialists invoked when domain expertise mattered? Did review surface blockers that should have been pre-flighted in research/build?
5. **pr** — Did the PR have everything (screenshots, test plan, ticket link, reviewer notes)?

## Save lessons at the right level

Match the lesson to the right persistence layer:

| Level | When to use | Example |
|---|---|---|
| **Memory** (per project) | One-off project facts, user feedback patterns, surprising project-specific gotchas | "Tuffgal stories must use real user actions, not engineer behaviors" |
| **CLAUDE.md** (per project) | Conventions, standing rules, hard constraints the project enforces | "Migrations must pass Squawk; start with lock_timeout = '1s'" |
| **Skill body** (cross-project) | Patterns that should apply to ALL projects this looper runs in | "For color work, pull WCAG thresholds in research before build picks values" |
| **Agent body** (cross-project) | Orchestration patterns, subagent invocation rules | "Web UI requires a11y-lead pre-build gate" |

If a skill caused the failure (missing checklist item, vague advice, blind spot), propose an edit to the skill body — don't just leave a memory. Memories are evidence; skill edits are fixes.

## What NOT to save

- Code patterns derivable from current code (a `git blame` or `grep` will find them)
- Fix recipes (the commit / PR carries that)
- Ephemeral task details
- Anything already in CLAUDE.md or an existing memory — update instead of duplicate

## Output

- List of new/updated memory files (with paths)
- List of CLAUDE.md edits (with paths)
- List of skill or agent edits (with paths)
- One-paragraph "what this means for the next run" — concrete, not vibes

## Honest self-assessment

If a step repeatedly fails the same way across multiple loops, the skill needs editing — not another memory. If the agent's orchestration logic is the issue, propose an agent edit. If the failure is environmental (missing tool, missing access), say so plainly — don't paper over it.

Looper improves only when learn is brutally honest about what went wrong.
