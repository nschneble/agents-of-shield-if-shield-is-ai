---
name: looper-verify
description: Verify bugfixes and feature implementations. Trigger when the user says "verify this bugfix" or "confirm this feature works."
---

Functional verification only. Does change do what spec said? Distinct from review (qualitative).

## What verify does

1. Re-read original spec (bug report, feature request, PRD)
2. List acceptance criteria (explicit or implied)
3. Exercise change against EACH criterion:
   - **Bugs:** confirm original repro no longer triggers; confirm fix at root cause, not symptom patch
   - **Features:** run feature end-to-end. Browser for UI (start dev server, click through). curl/HTTP for APIs. Real DB for migrations.
4. Cover golden path + 2–3 edge cases per spec + common sense
5. Confirm no regressions in adjacent functionality. Run existing tests if available.

## For UI changes specifically

- Start `npm run dev` (or project equivalent), click through feature in real browser
- If visual regression tests exist (Tuffgal, Percy, Chromatic), run them — but human approval of baseline diffs owed to user, not auto-claimed
- Screenshot or describe what observed. Do NOT claim "works" without seeing it work. Type-check + test pass = correctness; UI verification need eyeballs.
- Accessibility: keyboard-test feature (Tab/Shift-Tab through focusable elements, Enter/Space to activate). Screen-reader testing owed to post-build a11y-lead review pass, not verify — but flag if focus order or ARIA seem off.

## For API changes specifically

- Hit endpoint with curl or HTTPie. Confirm response shape, status code, error paths
- Confirm auth boundary holds (try without token, with wrong token, with expired token if applicable)
- Confirm DB state matches what endpoint claims it did

## For CSS / token plumbing specifically

When change = "rename CSS variable," "introduce new design token layer," "rethread token through cascade" — no new behavior, only new wiring — dev-server eyeball step add marginal signal over cheaper triangulation:

1. **Compiled-CSS grep.** After `npm run build` (or framework equivalent) grep emitted CSS for each new/renamed variable. Confirm:
   - Default declarations present
   - Per-theme/scope overrides present where intended
   - Cascade order in output right (more-specific selectors after less-specific in source order)
2. **Class-string unit test.** Render consuming component(s) in jsdom, assert their `className` strings contain `bg-[var(--new-var)]` / equivalent. Pins consumer side so future refactor cannot silently disconnect token from consumer.
3. **Math against thresholds.** If new color tokens, run WCAG 2.2 contrast formula against bundle-bg AND any adjacent surface (page-bg) token touches. Visual eyeballing reliably miss borders right above 3:1 in one context but fail in another.

If change layers new behavior (new component, animation, layout) on top of token plumbing, fall back to full UI verify path — visual outcome no longer purely function of tokens.

## For documentation / PR-body / config waves specifically

Non-code waves verify by reading back the resource and confirming the change applied. No dev-server, no curl, no DB query.

- **PR body / GitHub release:** `gh pr view <N> --json body | jq -r .body` (or `gh release view`). Confirm:
  - New body present (not truncated, not encoding-mangled)
  - Stale references the wave removed are gone (grep against the inventory list plan emitted)
  - Required sections present (Summary, Test plan, etc per template)
- **External config (CI yaml, eslintrc, package.json):** read file back, run config validator if present (`gh workflow run --dry`, `eslint --print-config`). Confirm change parses + downstream consumer reads it (run one CI step that consumes the config).
- **Documentation-only:** read file back, run markdownlint + the grep checks plan staged (stale-ref count, heading-hierarchy, link integrity via `markdown-link-check` if available). For docs that index project state (THEMES.md, CHANGELOG, ARCHITECTURE.md), confirm doc's claims match current code state — e.g. theme count in THEMES.md matches actual theme files on disk.

For all three: NO new behavior to exercise. Verify pass = "the resource now says what plan said it should say, and downstream consumers can still read it."

## What verify does NOT do

- Does NOT critique code structure → review's job
- Does NOT bike-shed naming or style → review's job
- Does NOT rerun lint/test/build → build skill already passed those before declaring done
- Does NOT propose alternative implementations → review's job if at all

## Output

PASS / FAIL verdict per acceptance criterion.

For FAIL, cite:

- Which criterion failed
- Observed behavior vs expected behavior
- File / line / step where gap is
- Fix size estimate: small (loop back to build with delta) or large (escalate to orchestrator)

If FAIL twice with same root cause → STOP and report to orchestrator. Do not loop indefinitely.
