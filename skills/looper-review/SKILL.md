---
name: looper-review
description: Perform independent code reviews of bugfixes and feature implementations. Trigger when the user says "do a code review", "review this bugfix", or "review this feature."
---

Qualitative review. Independent of build + verify. The question is not "does it work" — verify already answered that — it is "is this the right shape, does it fit the codebase, what are the hidden costs?"

## Invoke specialist reviewers

For domains beyond general engineering, the orchestrator invokes specialists via Task tool. This skill recommends which to invoke and synthesizes their reports:

| Domain | Reviewer |
|---|---|
| General code review | `the-diamantaire` |
| Convention adherence (style, naming, project patterns) | `the-stickler` |
| Accessibility (post-build review of shipped UI) | `accessibility-agents:accessibility-lead` |
| Test coverage and quality | `the-chemist` |
| Documentation | `the-chronicler` |
| Refactor / simplification opportunities | `the-improver` |

Invoke the relevant specialists in parallel where possible. Synthesize their findings — do not just concatenate.

## What to look for

- **Design fit:** does the change match the codebase's existing patterns? If it introduces a new pattern, is the new pattern better, or just different?
- **Hidden costs:** does the change add bundle weight, runtime cost, DB load, or maintenance burden disproportionate to its value?
- **Regression risk:** could this break adjacent code? Tests cover the change, but do they cover the seams between the change and what it touches?
- **Spec drift:** does the implementation match the spec, or did build sneak in scope? (Compare against the PRD / bug report / research output.)
- **Long-term readability:** in 6 months, will this be obvious to read, or load-bearing in a confusing way?
- **Domain blind spots:** for UI, were a11y patterns followed? For auth, are tokens and sessions handled safely? For DB, are migrations safe under concurrent writes?

## Don't do

- Don't re-run lint / test / build (verify's job, build already passed)
- Don't bike-shed naming or whitespace
- Don't propose alternatives that are merely-different, not better
- Don't pile on. If you find a blocker, surface it cleanly; don't bundle five nits with it

## Output

Three categories of findings:

- **🚫 Blocker** — must fix before merge. Cite file:line + reason + suggested resolution if obvious.
- **⚠ Warning** — should fix soon, ship-blockable only if review pass keeps surfacing the same warning. Cite file:line + reason.
- **💭 Nit** — optional improvement. No action required from the loop. Save for next refactor pass.

End with a verdict line:
- `ship` — no blockers, warnings acceptable
- `fix-blockers-then-ship` — blockers exist but are surgical fixes
- `rethink` — the approach is wrong; surfaced findings indicate the change needs redesign, not patches

If verdict is `rethink` → STOP and escalate to user. Do not loop into build with the same approach.
