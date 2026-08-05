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

## Executable verification function (where an oracle exists)

An LLM judge alone cannot be the sole completion gate — the best frontier long-context model scores only ~11% at agent-trace error-localization ([TRAIL, arxiv 2505.08638](https://arxiv.org/abs/2505.08638)). So WHERE a runnable oracle exists or is cheaply generatable, pair the judgment above with an EXECUTABLE verification function (VF): a generated test/assertion in the wave's language that automation runs. Its pass — not the LLM's say-so — is the completion gate.

- **Conditional, not universal.** Required only where an oracle is feasible. A prose / markdown / spec / docs wave with no runnable oracle CANNOT fabricate one: executable VF = N/A — fall back to the coherence + internal-consistency checks below. Never invent a test for a one-line doc fix.
- **Distinct from the build's suite.** The VF asserts THIS wave's acceptance criteria; it is not a rerun of the regression suite build already passed. The compiled-CSS grep, class-string jsdom test, contrast math, and endpoint curl below all already qualify.
- **Unseen-test robustness guard.** Where a test oracle exists, don't only re-run the cases the executor saw or wrote — that overfits to the tests the build targeted. Exercise UNSEEN cases (inputs / edges beyond the visible set) to confirm the change generalizes ([CodeTree, arxiv 2411.04329](https://arxiv.org/abs/2411.04329)). Same conditionality: no oracle, no hidden-test step.

### Held-out composition check (pre-registered, independent of the visible suite)

The unseen-case guard above still draws its cases from the same tests the build wrote — it widens coverage but inherits the build's blind spots. A held-out composition check closes the remaining gap: it is one more axis of this same executable-VF doctrine, not a parallel gate. Its defining property is INDEPENDENCE from the build's own visible tests — it composes the wave's shipped features end to end and asserts the plan brief's contract, not the assertions the build targeted. ([SpecBench, arxiv 2605.21384](https://arxiv.org/abs/2605.21384)) measured why this matters: "while every frontier agent saturates the visible suite, reward hacking persists" on held-out tests that compose the same features. "All visible checks pass" is not a sufficient verify signal.

- **Pre-registration is the mechanism — a pre-flight requirement, not an option.** The held-out scenario is authored from the PLAN BRIEF (what the wave is supposed to do, end to end) BEFORE the build phase begins, parked verbatim (the wave's `local/` artifacts are the natural home), and run UNMODIFIED at verify time. Authoring it after the build has run — or editing it so it passes — voids the check: it then only re-encodes what the build already made true, which is exactly the reward-hacking failure it exists to catch. Say so explicitly in the hand-back if either happened.
- **Blindness has two strengths — name which one you have.** Within a single executor context the blindness is only *procedural*: the same agent authored the build and the scenario, so independence rests on the pre-registration discipline alone. An orchestrated run strengthens it to *structural* — the orchestrator, or a separate fresh dispatch, authors the scenario from the brief alone, having never seen the build. Report which mode applied; the procedural mode is the weaker one and should be labeled as such, not dressed up as independent verification.
- **Scope — the same line the oracle rule draws.** Applies only to waves shipping runtime code where an executable oracle exists (the exact conditionality of the VF above). Doc-only / prose / trivial waves are exempt — there is nothing to compose. ONE held-out scenario per wave, not a parallel suite: a second suite is just more visible tests to overfit to.
- **Report the two results separately.** The visible-suite result and the held-out result are reported as distinct lines. A held-out FAIL on a wave whose visible suite is green is a FIRST-CLASS verify failure — it takes the same fail path as any other verify failure (loop back to build, or STOP on the second same-root-cause fail), never a footnote or an "advisory." The held-out run is executable evidence, so the verify gate line records `verified_by: executable` — the exact value PR #31's G3 guardrail checks with the `jq` equality predicate `.verified_by == "executable"`.

## Standing regression assertions (guardrails graduated from past failures)

A failure that recurred is one `looper-learn` may graduate into a **durable check** (its `## Recurring failure → durable guardrail`). Where that check is an executable assertion, it lands HERE — a standing verification function that runs on every wave whose change could re-trigger the original failure, not only the wave that first hit it.

- **Scope by trigger, not by wave.** A graduated assertion declares what it guards (a file, a contract, an invariant). Verify runs it whenever this wave's diff touches that surface — so the regression can't silently come back three waves later in a different change. A wave that touches nothing the assertion guards skips it.
- **Same oracle conditionality** as the VF above: a guardrail only graduates here if it's runnable. A failure with no runnable oracle becomes a policy line or a checklist item (learn's table), not a fake test.
- **Cite its origin.** Each standing assertion names the failure that motivated it (the cited incident / memory), so a future reader knows why it exists and a stale one can be retired with evidence, not guesswork. Adopting one is a normal proposed edit — verify hosts the assertion; it doesn't self-install it.
- **The registry that hosts these.** Graduated executable assertions live in `~/.claude/scripts/correction-gates/` — one spec-driven entry per correction, each `spec.md` citing the memory/correction it came from; `~/.claude/scripts/correction-gates/run-correction-gates.sh` runs every enabled entry scoped by its declared trigger. The registry ships in the looper definitions repo and deploys to `~/.claude/scripts/`, so it resolves from any cwd — a repo-relative `scripts/…` path would not, and verify runs inside TARGET repos that have no such directory. Cite it absolutely or the gates silently never run and verify still reports green. Registering a correction here is the corrections→gates compile step: a recurring correction becomes an enforced check instead of prose recall a later wave can re-violate.

## For UI changes specifically

- Start `npm run dev` (or project equivalent), click through feature in real browser
- If visual regression tests exist (Tuffgal, Percy, Chromatic), run them; human approval of baseline diffs owed to user, not auto-claimed
- Screenshot or describe what observed. Do NOT claim "works" without seeing it work. Type-check + test pass = correctness; UI verification need eyeballs.
- Accessibility: keyboard-test feature (Tab/Shift-Tab through focusable elements, Enter/Space to activate). Screen-reader testing owed to post-build a11y-lead review pass, not verify, but flag if focus order or ARIA seem off.

## For API changes specifically

- Hit endpoint with curl or HTTPie. Confirm response shape, status code, error paths
- Confirm auth boundary holds (try without token, wrong token, expired token if applicable)
- Confirm DB state matches what endpoint claims it did

## For CSS / token plumbing specifically

Change = "rename CSS variable," "introduce new design token layer," "rethread token through cascade" (no new behavior, only new wiring). Dev-server eyeball step add marginal signal over cheaper triangulation:

1. **Compiled-CSS grep.** After `npm run build` (or framework equivalent) grep emitted CSS for each new/renamed variable. Confirm:
   - Default declarations present
   - Per-theme/scope overrides present where intended
   - Cascade order in output right (more-specific selectors after less-specific in source order)
2. **Class-string unit test.** Render consuming component(s) in jsdom, assert `className` strings contain `bg-[var(--new-var)]` / equivalent. Pins consumer side so future refactor cannot silently disconnect token from consumer.
3. **Math against thresholds.** New color tokens → run WCAG 2.2 contrast formula against bundle-bg AND any adjacent surface (page-bg) token touches. Visual eyeballing reliably miss borders right above 3:1 in one context but fail in another.

Change layers new behavior (new component, animation, layout) on top of token plumbing → fall back to full UI verify path. Visual outcome no longer purely function of tokens.

## For documentation / PR-body / config waves specifically

Non-code waves verify by reading resource back, confirming change applied. No dev-server, no curl, no DB query.

- **PR body / GitHub release:** `gh pr view <N> --json body | jq -r .body` (or `gh release view`). Confirm:
  - New body present (not truncated, not encoding-mangled)
  - Stale references wave removed are gone (grep against inventory list plan emitted)
  - Required sections present (Summary, Test plan, etc per template)
- **External config (CI yaml, eslintrc, package.json):** read file back, run config validator if present (`gh workflow run --dry`, `eslint --print-config`). Confirm change parses + downstream consumer reads it (run one CI step that consumes config).
- **Documentation-only:** read file back, run markdownlint + grep checks plan staged (stale-ref count, heading-hierarchy, link integrity via `markdown-link-check` if available). Docs that index project state (THEMES.md, CHANGELOG, ARCHITECTURE.md) → confirm doc's claims match current code state, e.g. theme count in THEMES.md matches actual theme files on disk.

All three: NO new behavior to exercise. Verify pass = "resource now says what plan said it should say, and downstream consumers can still read it."

## What verify does NOT do

- Does NOT critique code structure → review's job
- Does NOT bike-shed naming or style → review's job
- Does NOT rerun lint/test/build → build skill already passed those before declaring done
- Does NOT propose alternative implementations → review's job if at all

## Output

PASS / FAIL verdict per acceptance criterion.

**Report the verdict's provenance in the gate log's `verified_by` vocabulary** (`loop-de-looper` → `## Gate artifacts`), so the wave's hand-back states it in the same terms any gate line records: `executable` when an executable verification function's pass was the completion gate (`## Executable verification function`), `llm` when the criterion had no runnable oracle and the verdict rests on the coherence / internal-consistency judgment instead. A prose/markdown/spec wave with `executable VF = N/A` reports `llm` — honestly, not dressed up as a check that never ran. Mixed criteria (some executable, some judged) report `executable` only when the *completion gate itself* was the runnable pass. Verify is a step inside the wave, not itself a `gates.jsonl` line — this provenance travels in the hand-back, where the orchestrator can carry it into the terms it records.

FAIL → cite:

- Which criterion failed
- Observed behavior vs expected behavior
- File / line / step where gap is
- Fix size estimate: small (loop back to build with delta) or large (escalate to orchestrator)

FAIL twice with same root cause → STOP and report to orchestrator. No loop indefinitely.
