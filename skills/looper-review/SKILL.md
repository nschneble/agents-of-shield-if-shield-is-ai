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

Each crew reviewer's bar is fixed **before** the diff is seen — curated upfront, not improvised by the judge at review time (VeriLA, arxiv 2503.12651: "defines clear expectations of each agent by curating human-designed agent criteria"). Recommend a reviewer → you assert the criteria below are the gate it'll be held to. The specialist's own agent def is source of truth; this is the contract the loop expects it to enforce. Surfaces per-agent failures instead of one floating, made-up bar.

- **`the-diamantaire`** (general code review): module-boundary violations + business logic delegated out of controllers; god files (~100 lines); N+1 / Prisma over-fetch / missing transaction; wrong NestJS exception (P2025 → `NotFoundException`) + missing `@UseGuards`; broken React form-state sequence + `createContext(undefined)` guard hook; rung fit (no rung-6 custom where stdlib/platform/dep covers); findings confidence-scored, only ≥75 surfaced, each cited `file:Lstart-Lend`.
- **`the-stickler`** (convention adherence): forbidden abbreviations + single-char vars; `handle*` / `on*` / `*Props` / `*Input` suffixes; `class` DTO vs `interface` shape vs `type` union; Tailwind class order (layout → sizes → margins → paddings → backgrounds → borders → text → focus → rounded → shadows); barrel `index.ts` per module; rule quoted verbatim when invoked.
- **`accessibility-agents:accessibility-lead`** (shipped UI): WCAG SC met at every real paint site; contrast measured not asserted; `aria-hidden` on decorative icons + explicit `role`/label on interactive elements; focus visible + keyboard reachable; live-region announcement where state changes.
- **`the-chemist`** (test coverage and quality): every error branch covered (P2025 → `NotFoundException`), not just happy path; tests assert real behavior, never mock plumbing; `*.spec.ts` back-end / `*.test.tsx` front-end; query by role/label not class/test-id; at least one integration test mirroring a real user flow.
- **`the-chronicler`** (documentation): external contracts thorough (Swagger + `@ApiProperty` + README), internal code WHY + gotchas only; no JSDoc echoing the type signature; comment style (wrap 75, lowercase single-line, no blank before JSDoc tags).
- **`the-improver`** (refactor / simplification): extract at 3+ repeats, not before; god-file split (100+ suspicious, 200+ guilty); ladder walk (delete → stdlib → platform → existing dep → one-line) before reshaping custom code; behavior preserved exactly (existing tests pass unedited); scope to changed code, no drive-by refactors.

## What to look for

- **Design fit:** change match existing patterns? New pattern = better, or different?
- **Rung fit:** approach sit at right ladder rung (YAGNI → stdlib → platform → existing dep → one-liner → minimal custom)? Rung-6 custom code where rung 2/3/4 (stdlib / platform / existing dep) cover? Plan brief named rung; implementation match? Downgrade opportunity (custom → one-liner → existing dep) = blocker or warning by cost. Escape-hatch claims (perf, a11y, security, data-loss, trust), verify requirement real, not asserted.
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