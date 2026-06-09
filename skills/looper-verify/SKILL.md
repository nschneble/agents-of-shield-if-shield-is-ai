---
name: looper-verify
description: Verify bugfixes and feature implementations. Trigger when the user says "verify this bugfix" or "confirm this feature works."
---

Functional verification only. Does the change do what the spec said it would do? Distinct from review (which is qualitative).

## What verify does

1. Re-read the original spec (bug report, feature request, PRD)
2. List acceptance criteria (explicit or implied)
3. Exercise the change against EACH criterion:
   - **Bugs:** confirm the original repro no longer triggers; confirm the fix is at root cause, not a symptom patch
   - **Features:** run the feature end-to-end. Browser for UI (start dev server, click through). curl/HTTP for APIs. Real DB for migrations.
4. Cover golden path + 2–3 edge cases per the spec + common sense
5. Confirm no regressions in adjacent functionality. Run existing tests if available.

## For UI changes specifically

- Start `npm run dev` (or project equivalent) and click through the feature in a real browser
- If visual regression tests exist (Tuffgal, Percy, Chromatic), run them — but human approval of baseline diffs is owed to the user, not auto-claimed
- Screenshot or describe what you observed. Do NOT claim "works" without seeing it work. Type-check + test pass is correctness; UI verification needs eyeballs.
- For accessibility: keyboard-test the feature (Tab/Shift-Tab through focusable elements, Enter/Space to activate). Screen-reader testing is owed to the post-build a11y-lead review pass, not verify — but flag if focus order or ARIA seems off.

## For API changes specifically

- Hit the endpoint with curl or HTTPie. Confirm response shape, status code, error paths
- Confirm auth boundary holds (try without token, with wrong token, with expired token if applicable)
- Confirm DB state matches what the endpoint claims it did

## For CSS / token plumbing specifically

When the change is "rename a CSS variable," "introduce a new design token layer," "rethread a token through the cascade" — i.e. no new behavior, only new wiring — the dev-server eyeball step adds marginal signal over a cheaper triangulation:

1. **Compiled-CSS grep.** After `npm run build` (or framework equivalent) grep the emitted CSS for each new/renamed variable. Confirm:
   - Default declarations are present
   - Per-theme/scope overrides are present where intended
   - Cascade order in the output is right (more-specific selectors after less-specific in source order)
2. **Class-string unit test.** Render the consuming component(s) in jsdom and assert their `className` strings contain `bg-[var(--new-var)]` / equivalent. This pins the consumer side so a future refactor cannot silently disconnect token from consumer.
3. **Math against thresholds.** If new color tokens, run the WCAG 2.2 contrast formula against bundle-bg AND any adjacent surface (page-bg) the token touches. Visual eyeballing reliably misses borders that are right above 3:1 in one context but fail in another.

If the change layers new behavior (a new component, animation, layout) on top of token plumbing, fall back to the full UI verify path — visual outcome is no longer purely a function of the tokens.

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
- File / line / step where the gap is
- Fix size estimate: small (loop back to build with delta) or large (escalate to orchestrator)

If FAIL twice with the same root cause → STOP and report to orchestrator. Do not loop indefinitely.
