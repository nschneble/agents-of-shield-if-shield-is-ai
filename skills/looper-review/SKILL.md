---
name: looper-review
description: Perform independent code reviews of bugfixes and feature implementations. Trigger when the user says "do a code review", "review this bugfix", or "review this feature."
---

Qualitative review. Independent from build + verify. Question not "does work" (verify answer that) but "right shape, fit codebase, hidden costs?"

## Invoke specialist reviewers

Domains beyond general eng → orchestrator invoke specialists via Task tool. Skill recommend + synthesize reports.

Under `loop-de-looper`, recommended specialists feed orchestrator's crew pass mechanism, fired at trigger points (every 4 waves OR 30 cumulative file changes, plus mandatory final crew), not per-wave parallel spawns inside wave loop. Per-wave review surface blockers/warnings/nits; crew pass on cumulative diff catch cross-wave drift single-wave review cannot see.

| Domain                                                 | Reviewer                                  |
| ------------------------------------------------------ | ----------------------------------------- |
| General code review                                    | `the-diamantaire`                         |
| Convention adherence (style, naming, project patterns) | `the-stickler`                            |
| Accessibility (post-build review of shipped UI)        | `accessibility-agents:accessibility-lead` |
| Test coverage and quality                              | `the-chemist`                             |
| Documentation                                          | `the-chronicler`                          |
| Refactor / simplification opportunities                | `the-improver`                            |

Invoke specialists parallel where possible. Synthesize findings, not concatenate.

## Pre-defined reviewer criteria

Each crew reviewer's bar is fixed **before** the diff is seen — curated upfront, not improvised by the judge at review time ([VeriLA, arxiv 2503.12651](https://arxiv.org/abs/2503.12651): "defines clear expectations of each agent by curating human-designed agent criteria"). Recommend a reviewer → you assert the criteria below are the gate it'll be held to. The specialist's own agent def is source of truth; this is the contract the loop expects it to enforce. Surfaces per-agent failures instead of one floating, made-up bar.

- **`the-diamantaire`** (general code review): correctness, module boundaries, exception/guard fit, rung fit — confidence-scored, only high-confidence surfaced.
- **`the-stickler`** (convention adherence): naming taboos, suffix conventions, DTO/shape/union choice, Tailwind class order, barrel structure — rule quoted verbatim.
- **`accessibility-agents:accessibility-lead`** (shipped UI): WCAG SC met and measured at every real paint site, decorative-vs-interactive ARIA, focus + keyboard reach, live-region announcements.
- **`the-chemist`** (test coverage and quality): every error branch covered, real-behavior assertions over mocked plumbing, role/label queries, at least one real-user-flow integration test.
- **`the-chronicler`** (documentation): external contracts thorough, internal comments WHY-only, comment-style conformance.
- **`the-improver`** (refactor / simplification): ladder walk before custom, god-file split, extract only at real repetition, behavior preserved, no drive-by scope.

## What to look for

- **Design fit:** change match existing patterns? New pattern = better, or different?
- **Rung fit:** approach sit at right ladder rung (YAGNI → stdlib → platform → existing dep → one-liner → minimal custom)? Rung-6 custom code where rung 2/3/4 (stdlib / platform / existing dep) cover? Plan brief named rung; implementation match? Downgrade opportunity (custom → one-liner → existing dep) = blocker or warning by cost. Escape-hatch claims (perf, a11y, security, data-loss, trust), verify requirement real, not asserted.
- **Speculative build (YAGNI):** structure, config hooks, abstraction, or params built for a need NOT in this wave's spec? Flag it. Cost is optionality + NPV (committed early on a guess, value deferred), NOT "only a few lines." Loop's cheap codegen is why this leaks — easier to over-build, never cheaper to own. Unused-future code shaping a public contract = blocker; otherwise warning. See `looper-plan` rung ladder, rung 1.
- **Hidden costs:** change add bundle weight, runtime cost, DB load, maintenance burden out of proportion to value?
- **Regression risk:** break adjacent code? Tests cover change, but cover seams between change + what touches?
- **Spec drift:** implementation match spec, or build sneak scope? (Compare vs PRD / bug report / research output.)
- **Long-term readability:** 6 months out, obvious to read, or load-bearing confusing?
- **Domain blind spots:** UI → a11y patterns followed? Auth → tokens + sessions safe? DB → migrations safe under concurrent writes?

## Don't do

- No re-run lint / test / build (verify job, build passed)
- No bike-shed naming or whitespace
- No propose alternatives merely-different, not better
- No pile on. Blocker found → surface clean; no bundle five nits with it

## Output

Three categories findings:

- **🚫 Blocker**: must fix before merge. Cite file:line + reason + suggested fix if obvious.
- **⚠ Warning**: should fix soon, ship-blockable only if review pass keep surfacing same warning. Cite file:line + reason.
- **💭 Nit**: optional improvement. No action required from loop. Save for next refactor pass.

End with verdict line:

- `ship`: no blockers, warnings acceptable
- `fix-blockers-then-ship`: blockers exist but surgical fixes
- `rethink`: approach wrong; findings show change need redesign, not patches

Verdict `rethink` → STOP + escalate to user. No loop into build with same approach.
