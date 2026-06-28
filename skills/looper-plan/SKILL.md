---
name: looper-plan
description: Produce tactical brief for a single wave between research and build. Trigger when the user says "plan this wave", "spec the wave", or "what's the brief for this change?"
---

Slot between research and build. Convert research constraints into wave-specific contract: files, deterministic predictions, recovery options pre-staged, exit criteria. Mechanize parts of a11y-lead / security review / migration review that math, lint, or grep answer. Escalate residual.

## Why plan exists

Research surface constraints abstract ("WCAG 1.4.11 needs 3:1 borders against bundle-bg"). Build need concrete ("THIS wave, 4 token pairs touched, predicted contrast value each, 2 fail + recovery option each").

No plan = build guess (surface palette right, miss contract math) or orchestrator invoke specialist subagent per wave (slow, block autonomy). Plan absorb deterministic portion of specialist judgment into runnable check; keep loop autonomous unless real judgment need.

## Inputs

1. `looper-research` output (structured report)
2. Project CLAUDE.md + nested `.claude/CLAUDE.md`
3. Project memory at `~/.claude/projects/<project>/memory/`
4. PRD if exist (default `local/prds/<feature-slug>.md`, else memory `reference-prds`)
5. Current branch state: `git status`, `git diff HEAD`, recent commits in scope

## Mechanized contract checks (the big idea)

Each domain plan support, run deterministic checks BEFORE handoff to build. Each check answer yes/no with citations; no judgment, no vibes.

| Domain                           | Mechanized check                                                                                                                                                                                                                                   | What it answers                                                                                        |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Color tokens / contrast / CVD    | Dry-run contract tests (`bundles.contrast.test.ts`, `bundles.distinguishability.test.ts`) against proposed token values via culori. WCAG 1.4.3 / 1.4.11 / CVD distinguishability.                                                                  | Will proposed palette pass contract? Which pairs fail? By how much?                                    |
| Component refactor / migration   | Grep tripwire tests (`chrome-token-migration.test.ts`-style) against proposed file list. Confirm MIGRATED_FILES entries.                                                                                                                           | Does the wave reach the tripwire? Any files miss the registration?                                     |
| Database migration               | `npm run lint:migrations` (Squawk) dry-run against proposed SQL                                                                                                                                                                                    | Squawk-clean? Which rules fire?                                                                        |
| Auth / token / permission        | Caller graph via grep: list every consumer of touched API surface                                                                                                                                                                                  | What public contracts shift? Any external clients (extensions, PATs)?                                  |
| Performance-sensitive code       | Baseline measurement before change (existing perf test or one-shot benchmark)                                                                                                                                                                      | What is the floor we cannot regress past?                                                              |
| Test gap (any domain)            | Coverage check on touched files; compare to suite-wide coverage                                                                                                                                                                                    | Tests cover the change? Coverage drop indicates gap.                                                   |
| Documentation / PR body / config | Markdownlint dry-run, grep for stale references (project file inventory vs claimed inventory in doc), heading-hierarchy check, link integrity (`markdown-link-check`), config validator dry-run (`eslint --print-config`, `gh workflow run --dry`) | Doc claims match current state? Stale references remain? Config parses + downstream consumers read it? |

Plan run check, capture output, cite. NEVER substitute judgment for unrun checks.

### Alias-chain trace for retirement waves

Retiring CSS variable, framework token, or any indirection target requires tracing every CONSUMER of target, including aliases from prior waves. Per-theme cascade resolution that flowed through retiring token will collapse to whatever orchestrator-introduced `:root` default is once per-theme declarations vanish.

Concrete trap from wave 39 / wave 40 of linklater theme refactor:

- Wave 39 added `--page-gradient-{from,via,to}: var(--text-muted)` etc. at `:root`. Per-theme cascades resolve alias against each theme's own `--text-muted` declaration. Per-theme tinting preserved with zero per-theme work.
- Wave 40 brief retired `--text` / `--text-muted` from per-theme files AND replaced `:root` aliases with literal hex. Effect: every theme's gradient collapse to same `:root` default hex pair. Wave-39 design intent silently lost.

Any retirement wave brief, plan MUST:

1. `git grep "var\(--TOKEN\)"` enumerate every consumer
2. Each consumer, trace whether consumer is itself token (alias); if so, every downstream consumer of THAT alias must also be considered
3. Walk chain until no consumer is itself token
4. Choose explicitly between two paths per retirement:
   - **Flatten:** Accept collapse. All downstream resolutions paint single `:root` default. Cheaper but visually uniform.
   - **Carry-forward:** Push resolved values down into per-theme overrides. Preserves per-theme paint. Mechanical (~3 lines × N themes × M modes) but right call when design intent depends on per-theme variation.

Brief MUST surface choice. Don't claim "no semantic change" when there is one.

### Rendering-context check for contrast-pair claims

Any mechanized check that assert contrast pair (`token-A vs token-B ≥ ratio`) MUST first verify what actually paints edge in consumer code. Same visual separation come from:

- `border-[var(--TOKEN)]`: token-A IS contract subject; assertion real
- `box-shadow` / shadow utility (`border-shadow`, ring, drop-shadow): NO WCAG pair; visual lift only
- Background-on-background adjacency: perceptual separation, not SC 1.4.11

`git grep` consumer code for `border-\[var\(--TOKEN\)\]` BEFORE asserting `--TOKEN` against anything. If consumer paints `border-shadow` or `box-shadow`, contract subject wrong; re-frame as perceptual-separation (label "card-on-X lift" or similar, NOT SC 1.4.11) or drop contract.

Example trap: brief asserting `--page-gradient-stop vs --mount-border ≥ 3:1` unsatisfiable if consumer cards use `border-shadow`. Card edge is shadow, not `--mount-border`; `--mount-border` never painted on those cards. Contract subject fictional.

When mechanizing perceptual-separation (background-on-background, shadow-edge-on-X), label correctly. Don't borrow SC numbers it doesn't earn.

### Grep authority: use `git grep`, not `grep -r`

Any mechanized check involving "find every consumer of X" or "verify zero consumers of Y" MUST use `git grep`, not `grep -r --include="*.{ext1,ext2}"`. Reasons:

- Bash brace expansion does NOT fire inside quoted strings. `--include="*.{tsx,ts,html}"` pass literal string `*.{tsx,ts,html}` to grep, matches nothing; silently scope search to zero files, return false zero.
- `git grep` respects `.gitignore` automatically, skip `node_modules`, `dist`, `.claude/worktrees/`, other agent-spawned trees that pollute results.
- `git grep` defaults to ignoring binary files and respects repo normalization.

Pattern to use:

```
git grep -nE "var\(--TOKEN\b" -- 'apps/web/src/**/*.tsx' 'apps/web/src/**/*.ts' 'apps/web/index.html'
```

Multiple extensions via repeated pathspecs (single-quoted), not via brace expansion.

False-zero consumer claims shipped broken retirement waves before; plan-stage STOP fires per `[[feedback-verify-upstream-gate-claims]]`, but cheaper failsafe is author grep correctly first place. Mechanized predictions section MUST include actual `git grep` command run + raw output, not paraphrased "verified zero consumers."

### UI-touching waves always tag `ui: true` + mandate accessibility-lead

`the-looper` is a SUBAGENT. The main-loop accessibility hook (`UserPromptSubmit` → "delegate to accessibility-lead") fires on the PARENT prompt, NOT inside a subagent dispatch. So a wave whose build edits UI source gets ZERO automatic accessibility pass — the executor can ship `.tsx` hands-off with no specialist review. Plan closes that gap deterministically: it detects UI-touching waves and mandates the gate, so the orchestrator runs accessibility-lead as a pre-build sibling pass (loop-de-looper Step 2b) instead of relying on a hook that never fires.

Detection is mechanical (a glob over the wave's touched-files list from section 1, NOT a judgment call). A wave is UI-touching if ANY touched file matches:

- Components / markup: `*.tsx`, `*.jsx`, `*.vue`, `*.svelte`, `*.html`
- Server-side templates: `*.leaf`, `*.ejs`, `*.erb`, `*.hbs`, Jinja/`*.j2`
- Styling that paints user-facing surface: `*.css`, `*.scss`, Tailwind config, design-token files (`tokens.json`, Style Dictionary)

Match → brief carries `UI: yes` in section 1 AND emits a mandatory `ESCALATE: accessibility-lead` pre-build gate (see `## Escalation to specialist`). NON-NEGOTIABLE; not subject to the mechanized-check absorption above. Contrast/token math plan can mechanize and cite (the contrast dry-runs); role/name/keyboard/focus judgment stays the specialist's. Plan mechanizes what it can AND still mandates the gate for the residual.

No UI file touched → `UI: no`, no accessibility-lead mandate. A pure backend / docs / config wave does not summon the specialist.

### When no mechanized check applies

Some waves match no domain: PR body refresh, README rewrite, GitHub release notes, project-config tweaks, doc-only changes. Real waves, plan still produce all seven output sections, but mechanized predictions section become:

> No mechanized check applies; wave touches `<change kind>`, not source under contract-tested domain. Risk register relies on `judgment-required` items only.

Honest output, not fallback. Other sections (scope, constraints, risk register, recovery options, exit criteria) still mechanize what can, e.g. PR body refresh, grep body against current deferred-items inventory; README rewrite, run markdown lint; config tweak, run config-schema validation.

## Output (hand to looper-build)

Structured brief, seven sections (plus `## Ranked alternate plans` below, which rides in the brief for non-trivial waves but is not one of the seven numbered Output sections):

1. **Wave scope**

   - Files touched (exact paths) OR change kind if no files touched (`PR body`, `GitHub release`, `external config`, `documentation`)
   - Regions within file (line ranges or function names) when narrower than whole-file
   - `UI: yes|no` — `yes` if any touched file matches a UI surface (see `### UI-touching waves always tag`). A `yes` MANDATES the accessibility-lead gate in the escalation section, fired up-front by the orchestrator.
   - Blast radius estimate. Code waves: files + lines + downstream consumers. Non-file waves: user-visible impact surface (e.g. "PR description on github.com: visible to reviewers + repo browsers", "release notes: visible on releases page + automated changelog feeds").

2. **Constraints (cited)**

   - Each constraint = one line: `RULE – SOURCE (file:line or URL)`. No paraphrase, cite original
   - Example: `state-pair CVD JND >= 10 (delta-E 2000) – bundles.distinguishability.test.ts:42`

3. **Rung (the ladder, named)**

   State minimum-viable rung chosen approach sits at, and why:

   1. YAGNI (skip) 2. Stdlib 3. Platform/framework native 4. Existing installed dep 5. One-liner 6. Minimal custom

   - Rung 6 (custom) requires named justification: perf, a11y, security, data-loss, trust-boundary, OR real requirement from research that no lower rung satisfies. Cite requirement (`research §X` or `file:line`).
   - One line: `Rung N – <approach in 5 words> – <why this rung>`.
   - Bias, not rule. Lower rung wins ties; escape hatches must be named.
   - **Rung 1 (YAGNI) is the default, and its cost is not typing.** Building structure for a need that has not arrived spends two things cheap codegen cannot refund: _optionality_ — waiting holds the option to build once the real need is known; exercise it early on a guess and you usually guess wrong, guess right and you still burn the info waiting would have handed you ("waiting is holding an asset") — and _NPV_ — cost paid this wave, value lands some later wave = time-value loss. Looper generates code cheaply; that makes over-build EASIER, never CHEAPER. "It's only a few lines, the loop writes them free" is the exact trap. Skip it; let a future wave build it when the need is real. Source: Kent Beck, "The Cost YAGNI Was Never About" (https://newsletter.kentbeck.com/p/the-cost-yagni-was-never-about).

4. **Mechanized predictions**

   - Each check run, output verdict + numeric proof
   - Example: `bundle-contrast on `apollo-10-1-2` dark mount-border vs mount-bg: 1.82:1 (FAIL, needs 3:1). Recovery A: lift bg lum by 0.04 -> 3.12:1 (PASS).`
   - Cite source file + line every threshold

5. **Risk register**

   - What still go wrong that mechanized checks cannot catch (rendering-context judgment, novel palette, brand-locked constraint)
   - Severity tag: `mechanizable-residual` (previously-deferred check could catch this; queue) vs `judgment-required` (escalate to specialist)

6. **Recovery options pre-staged**

   - Each predicted failure, primary fix + fallback. Build pick one; no improvise
   - Example: `state-pair info vs success collapse under deuteranopia. Option A: shift info lum +0.06. Option B: bring shape redundancy in consuming component`

7. **Exit criteria**
   - Concrete: "wave done when N files migrated, contract tests green, no new lint warnings"
   - Used by verify + review to confirm "wave done" objectively

## Ranked alternate plans (retry fuel for non-trivial waves)

Recovery options (#6) patch a _predicted_ failure inside the primary plan — build applies one mid-wave. Ranked alternate plans are a different altitude: whole-approach fallbacks for when the primary plan _wedges_ (verify fails twice, review says rethink) and the orchestrator's stuck-wave retry (`loop-de-looper` 2b-retry) needs a DIFFERENT approach. Pre-rank them now, while research context fresh, so the retry reverts to a vetted next plan instead of improvising one cold.

Source: MapCoder (ACL 2024) — generate k confidence-ranked plans; on failure, revert to the next-highest-confidence plan rather than re-running the failed one (O(kt) for k plans, t repair turns).

Proportional — rank only where the wave has genuine alternatives:

- **Non-trivial wave, real approach alternatives** → emit the primary plus exactly 1 ranked fallback. The 2b-retry is ONE-SHOT, so only Fallback 1 is ever consumed inside the loop — a second fallback is unreachable retry fuel; don't manufacture it. The fallback = one line: the alternate approach + a one-line confidence rationale (why it ranks below the primary, what it trades).
- **One-line fix / single mechanical change / one viable approach** → primary only. State it: "no ranked alternates — single viable approach." Manufacturing fake fallbacks for a trivial wave is noise; the retry then improvises from the failure signal, correct when there genuinely is no second approach.

Shape:

> **Primary (confidence: high)** — `<approach>`. `<why it leads>`.
> **Fallback 1 (confidence: medium)** — `<different approach>`. `<what it trades vs primary, e.g. "more files touched, sidesteps the shared-state coupling the primary risks">`.

Rank by confidence the approach SHIPS the wave clean, not by ease. Fallbacks are real plans: each must still satisfy the wave's constraints (#2) + exit criteria (#7) and pass the same mechanized predictions (#4). A fallback that can't clear the same checks is not a fallback — drop it.

Build executes the primary only. The ranked list rides in the brief and surfaces in the wave hand-back, so a later retry has a pre-vetted place to go (see `loop-de-looper` 2b-retry mechanic 2). One shot per wave still holds: the retry consumes the next-ranked plan, it does not walk the whole list.

## Escalation to specialist (the residual path)

Mechanizable checks cover most cases. Some categories ALWAYS escalate even when mechanized pass:

- **Any UI-touching wave** (`UI: yes` per `### UI-touching waves always tag`). The accessibility-lead gate is mandatory and fires up-front — the executor subagent never triggers the main-loop accessibility hook, so plan mandates it here. Emit `ESCALATE: accessibility-lead` even when contrast/token math mechanized clean; role/name/keyboard/focus judgment is unmechanizable residual.
- **Brand-locked palette decisions** (e.g. landing page hardcoded white-on-navy). Mechanized check tell contrast value; only specialist tell whether palette can shift.
- **Novel palette / new theme.** No historical baseline for delta-E sanity; specialist must vet.
- **Rendering-context mismatch.** Mechanized check assume import location = host bundle. Shared components render under DIFFERENT host bundle than import directory. Plan flag suspicion; specialist judge.
- **Public API contract changes** (auth surface, extension API). Mechanized check catch caller list; specialist review threat model.

When escalation need, plan emit one line per gate: `ESCALATE: <gate name> – <input to pass> – <output looper-build needs to resume>`. Orchestrator route; build stop until orchestrator return gate output.

## What plan does NOT do

- Plan NOT pick final values. Recovery options offered; build decide which apply (within constraints).
- Plan NOT write code. Mechanized checks read existing files + dry-run tests. No `Edit` / `Write` to source.
- Plan NOT replace specialist for judgment-required residuals. Mechanized checks cover deterministic surface; specialists own rest.
- Plan NOT re-research. Constraint missing, send back to research, do not invent.
- Plan NOT manufacture ranked alternates for a trivial wave (`## Ranked alternate plans`).

## Stop conditions

- Research output ambiguous on critical decision (target files, expected behavior) → STOP. Send back to research.
- Mechanized check infra missing (test file no exist, culori not installed, Squawk config absent) → STOP. Surface infra gap to orchestrator BEFORE proceed.
- All recovery options fail own predictions → STOP. Escalate to user; palette / architecture decision need, not wave.
- Wave scope exceed research-stated blast radius by 2x or more → STOP. Scope challenge per memory `[[feedback-refactor-staging]]`.
- Specialist gate required AND orchestrator unable to invoke (Task tool absent) → STOP. Hand-off report, do not pretend gate ran. Per memory `[[feedback-task-tool-availability]]`.

## Voice + style

Match existing looper skill voice. Cite, no paraphrase. Numbers, not vibes. Constraint from file, cite `file:line`. From URL, cite URL. From project memory, cite `[[memory-name]]`.

Brief MUST be re-readable by future loop with no prior context. Self-contained.
