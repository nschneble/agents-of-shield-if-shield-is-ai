---
name: looper-review
description: Perform independent code reviews of bugfixes and feature implementations. Trigger when the user says "do a code review", "review this bugfix", or "review this feature."
---

Qualitative review. Independent from build + verify. Question not "does work" (verify answer that) but "right shape, fit codebase, hidden costs?"

## Invoke specialist reviewers

Domains beyond general eng → orchestrator invoke specialists via Task tool. Skill recommend + synthesize reports.

Under `loop-de-looper`, recommended specialists feed orchestrator's crew pass mechanism, fired at trigger points (every 4 waves OR 30 cumulative file changes, plus mandatory final crew), not per-wave parallel spawns inside wave loop. Per-wave review sorts findings into blockers and batched, same two buckets as `## Output`; crew pass on cumulative diff catch cross-wave drift single-wave review cannot see.

| Domain                                                 | Reviewer                                  |
| ------------------------------------------------------ | ----------------------------------------- |
| General code review                                    | `the-diamantaire`                         |
| Convention adherence (style, naming, project patterns) | `the-stickler`                            |
| Accessibility (post-build review of shipped UI)        | `accessibility-agents:accessibility-lead` |
| Test coverage and quality                              | `the-chemist`                             |
| Documentation                                          | `the-chronicler`                          |
| Voice and tone (prose surfaces, AI-slop tells)         | `the-ghostwriter`                         |
| Refactor / simplification opportunities                | `the-improver`                            |

Invoke specialists parallel where possible. Synthesize findings, not concatenate.

## Pre-defined reviewer criteria

Each crew reviewer's bar is fixed **before** the diff is seen — curated upfront, not improvised by the judge at review time ([VeriLA, arxiv 2503.12651](https://arxiv.org/abs/2503.12651): "defines clear expectations of each agent by curating human-designed agent criteria"). Recommend a reviewer → you assert the criteria below are the gate it'll be held to. The specialist's own agent def is source of truth; this is the contract the loop expects it to enforce. Surfaces per-agent failures instead of one floating, made-up bar.

- **`the-diamantaire`** (general code review): correctness, module boundaries, exception/guard fit, rung fit — confidence-scored, only high-confidence surfaced.
- **`the-stickler`** (convention adherence): naming taboos, suffix conventions, DTO/shape/union choice, Tailwind class order, barrel structure — rule quoted verbatim.
- **`accessibility-agents:accessibility-lead`** (shipped UI): WCAG SC met and measured at every real paint site, decorative-vs-interactive ARIA, focus + keyboard reach, live-region announcements.
- **`the-chemist`** (test coverage and quality): every error branch covered, real-behavior assertions over mocked plumbing, role/label queries, at least one real-user-flow integration test.
- **`the-chronicler`** (documentation): external contracts thorough, internal comments WHY-only, comment-style conformance.
- **`the-ghostwriter`** (voice and tone): prose surfaces read like Nick wrote them — no em-dashes, no slop vocabulary, no commit-linked comment archaeology, per-surface case/punctuation matrix respected. Findings only in crew mode, no edits.
- **`the-improver`** (refactor / simplification): ladder walk before custom, god-file split (by lines of code, docs excluded), extract only at real repetition, behavior preserved, no drive-by scope.

## What to look for

Read the wave's goal contract FIRST — under `loop-de-looper` the brief carries it verbatim (`loop-de-looper` `## Goal contract`). It is what the run was asked for, and every finding below is measured against it plus the diff this wave actually produced. A finding about neither is not a review finding; it is a future scope run.

- **Contract fit:** does the change close the ask it was queued to close? An implementation that is excellent and answers a different question is the most expensive defect on this list, and the only one that gets more convincing the longer a run goes.
- **Design fit:** change match existing patterns? New pattern = better, or different?
- **Rung fit:** approach sit at right ladder rung (YAGNI → stdlib → platform → existing dep → one-liner → minimal custom)? Rung-6 custom code where rung 2/3/4 (stdlib / platform / existing dep) cover? Plan brief named rung; implementation match? Downgrade opportunity (custom → one-liner → existing dep) = batched, whatever its cost; a rung too high is a refactor finding. Escape-hatch claims (perf, a11y, security, data-loss, trust), verify requirement real, not asserted — a FALSE escape-hatch claim covering a real defect is that defect, and blocks on its own class.
- **Speculative build (YAGNI):** structure, config hooks, abstraction, or params built for a need NOT in this wave's spec? Flag it. Cost is optionality + NPV (committed early on a guess, value deferred), NOT "only a few lines." Loop's cheap codegen is why this leaks — easier to over-build, never cheaper to own. Batched: unused-future code is code nobody called yet, so it regresses nothing. See `looper-plan` rung ladder, rung 1.
- **Hidden costs:** change add bundle weight, runtime cost, DB load, maintenance burden out of proportion to value?
- **Regression risk:** break adjacent code? Tests cover change, but cover seams between change + what touches?
- **Spec drift:** implementation match spec, or build sneak scope? (Compare vs PRD / bug report / research output.)
- **Long-term readability:** 6 months out, obvious to read, or load-bearing confusing?
- **Domain blind spots:** UI → a11y patterns followed? Auth → tokens + sessions safe? DB → migrations safe under concurrent writes?

## Don't do

- No re-run lint / test / build (verify job, build passed)
- No bike-shed naming or whitespace
- No propose alternatives merely-different, not better
- No pile on. Blocker found → surface clean; the batched findings go in their own list, not stapled to it as leverage

## Output

Every finding is cited `file:line` + reason + suggested fix if obvious, then sorted into one of two buckets by `loop-de-looper` `## Finding severity floor` — NOT by how serious it feels:

- **🚫 Blocker**: in a gating class (correctness regression in this run's diff, security, data loss, a11y regression on shipped UI, a false user-visible string) AND admissible — it cites a goal-contract ask it protects, or a `file:line` this run changed. These stop the wave.
- **📋 Batched**: everything else. Docs, comments, naming, conventions, LOC, test hygiene, oracle shape, refactor opportunities, voice, commit/PR prose, and anything pre-existing this run did not cause. Real findings, reported in full, fixed in the run's terminal cleanup wave.

The old middle category is gone on purpose. "⚠ Warning: should fix soon, ship-blockable if it keeps surfacing" is a blocker on a delay, and a reviewer with an incentive to re-surface is a reviewer that eventually gets its wave. A finding either meets the floor now or it batches.

**Severity is not the same axis as confidence.** A finding can be certain, well-cited, and still batched. Reviewers reach for Blocker to make sure a real defect gets fixed — the batch is what makes that unnecessary: nothing is dropped, it is scheduled.

End with verdict line:

- `ship`: no blockers; batched findings recorded
- `fix-blockers-then-ship`: blockers exist but surgical fixes
- `rethink`: approach wrong; findings show change need redesign, not patches

Verdict `rethink` → STOP + escalate to user. No loop into build with same approach. Two blockers in a row on the same wave is also a `rethink`, not a second patch (`loop-de-looper` `## Corrective budget`).
