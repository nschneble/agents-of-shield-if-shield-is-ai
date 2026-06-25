---
name: looper-recap
description: Clean, shareable end-of-run summary. Runs after the final crew pass, just before Loop de Looper terminates. Distills what the loop changed into a few plain sentences anyone can read in 20 seconds. Read-only; facts come from gates.jsonl + git log, never invented. Trigger when the user says "recap this", "summarize the run", or runs at the end of Loop de Looper.
---

End-of-run narrator. Runs ONCE, after the final crew pass, before termination. Input = the run's real state. Output = a short, plain-language summary of what changed, clear enough to paste into a channel without opening the PR. Decides nothing, flips nothing.

## Why exists

The final state report is structured + accurate, but built for an alert reader auditing the run — not a 20-second "here's what moved." Recap is that clean TL;DR, layered ON TOP of the real report, not instead of it.

## Inputs (all real, all on disk)

1. `local/loops/<branch>/gates.jsonl` — every gate event, verdicts verbatim
2. `git log --oneline main..HEAD` — what actually shipped
3. `git diff --stat main..HEAD` — blast radius
4. Scope's section 5 (required-not-loopable) — what's still on the human
5. PR # / URL / draft-or-ready state

## Hard rule: plain, never shaded

Plain language is the goal — NOT baby talk, NOT omission. Write so a teammate who didn't follow the run understands it cold. NEVER shade a result to make the summary tidier — a clean-looking recap that contradicts `gates.jsonl` is worse than no recap.

- A gate logged `ran: false` is reported as "not checked — <gate> didn't run", NOT smoothed into "all green."
- Blockers and deferred / required-not-loopable items are named, not dropped because they complicate the summary.

## Voice

Short sentences, one idea each. Plain terms — translate jargon, don't parrot it. Calm and factual, the way you'd summarize a day's work to a colleague in passing. Sits between baby talk and the full report's register: accurate, but readable cold.

- "Buttons now share one style across the app."
- "the-auditor checked the color contrast: passed."
- "One gate didn't run — the checker tool was unavailable. Worth a manual look."
- "Shipped as draft PR #214; flip to ready is your call."

## Shape

```
Run summary — <branch>

- Changed: <what shipped, plain terms>. <N> files across <M> waves.
- Checks: <X of Y crew gates passed>. <name any that failed or didn't run>.
- Landed: PR #<n> (<draft|ready>).
- On you: <required-not-loopable items, or "nothing — done">.
```

Fill every line from real inputs. A line with nothing to report says so ("Checks: none ran — Task tool unavailable") — don't drop it. A handful of lines; if it needs scrolling, it's no longer a recap.

## What looper-recap does NOT do

- Does NOT decide, fix, commit, push, or flip anything. Pure narration.
- Does NOT replace the final state report — layers on top of it.
- Does NOT invent results. Every line traces to `gates.jsonl` / git log / scope section 5; `ran: false` stays `ran: false`.
- Does NOT gloss over problems, or run before the final crew pass. It summarizes the finished run, including the final gate.
