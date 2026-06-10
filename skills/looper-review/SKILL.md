---
name: looper-review
description: Perform independent code reviews of bugfixes and feature implementations. Trigger when the user says "do a code review", "review this bugfix", or "review this feature."
---

Qualitative review. Independent from build + verify. Question not "does work" — verify answer that — but "right shape, fit codebase, hidden costs?"

## Invoke specialist reviewers

Domains beyond general eng → orchestrator invoke specialists via Task tool. Skill recommend which + synthesize reports.

Under `loop-de-looper`, recommended specialists feed the orchestrator's crew pass mechanism — fired at trigger points (every 4 waves OR 30 cumulative file changes, plus mandatory final crew), not per-wave parallel spawns inside the wave loop. Per-wave review surfaces blockers/warnings/nits; crew pass on cumulative diff catches cross-wave drift that single-wave review can't see.

| Domain                                                 | Reviewer                                  |
| ------------------------------------------------------ | ----------------------------------------- |
| General code review                                    | `the-diamantaire`                         |
| Convention adherence (style, naming, project patterns) | `the-stickler`                            |
| Accessibility (post-build review of shipped UI)        | `accessibility-agents:accessibility-lead` |
| Test coverage and quality                              | `the-chemist`                             |
| Documentation                                          | `the-chronicler`                          |
| Refactor / simplification opportunities                | `the-improver`                            |

Invoke specialists parallel where possible. Synthesize findings — not concatenate.

## What to look for

- **Design fit:** change match codebase existing patterns? New pattern = better, or different?
- **Hidden costs:** change add bundle weight, runtime cost, DB load, maintenance burden disproportionate to value?
- **Regression risk:** break adjacent code? Tests cover change, but cover seams between change + what it touches?
- **Spec drift:** implementation match spec, or build sneak scope? (Compare vs PRD / bug report / research output.)
- **Long-term readability:** 6 months out, obvious to read, or load-bearing confusing?
- **Domain blind spots:** UI → a11y patterns followed? Auth → tokens + sessions safe? DB → migrations safe under concurrent writes?

## Don't do

- No re-run lint / test / build (verify job, build passed)
- No bike-shed naming or whitespace
- No propose alternatives merely-different, not better
- No pile on. Find blocker → surface clean; not bundle five nits with it

## Output

Three categories findings:

- **🚫 Blocker** — must fix before merge. Cite file:line + reason + suggested resolution if obvious.
- **⚠ Warning** — should fix soon, ship-blockable only if review pass keep surfacing same warning. Cite file:line + reason.
- **💭 Nit** — optional improvement. No action required from loop. Save for next refactor pass.

End with verdict line:

- `ship` — no blockers, warnings acceptable
- `fix-blockers-then-ship` — blockers exist but surgical fixes
- `rethink` — approach wrong; findings indicate change need redesign, not patches

Verdict `rethink` → STOP + escalate to user. No loop into build with same approach.
