---
name: looper-plan
description: Produce tactical brief for a single wave between research and build. Trigger when the user says "plan this wave", "spec the wave", or "what's the brief for this change?"
---

Slot between research and build. Convert research's constraints into a wave-specific contract: files, deterministic predictions, recovery options pre-staged, exit criteria. Mechanize the parts of a11y-lead / security review / migration review that math, lint, or grep can answer. Escalate the residual.

## Why plan exists

Research surfaces constraints in the abstract ("WCAG 1.4.11 needs 3:1 borders against bundle-bg"). Build needs them concrete ("for THIS wave, here are the 4 token pairs touched, here is the predicted contrast value for each, here are the 2 that fail and the recovery option for each").

Without plan, build either guesses (gets surface-level palette right, misses contract-level math) or orchestrator invokes a specialist subagent per wave (slow, blocks autonomy). Plan absorbs the deterministic portion of specialist judgment into a runnable check — keeps the loop autonomous unless real judgment needed.

## Inputs

1. `looper-research` output (structured report)
2. Project CLAUDE.md + nested `.claude/CLAUDE.md`
3. Project memory at `~/.claude/projects/<project>/memory/`
4. PRD if exist (default `local/prds/<feature-slug>.md`, else memory `reference-prds`)
5. Current branch state — `git status`, `git diff HEAD`, recent commits in scope

## Mechanized contract checks (the big idea)

For each domain plan supports, run deterministic checks BEFORE handing off to build. Each check answers a yes/no question with citations — no judgment, no vibes.

| Domain                         | Mechanized check                                                                                                                                                                  | What it answers                                                       |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Color tokens / contrast / CVD  | Dry-run contract tests (`bundles.contrast.test.ts`, `bundles.distinguishability.test.ts`) against proposed token values via culori. WCAG 1.4.3 / 1.4.11 / CVD distinguishability. | Will proposed palette pass contract? Which pairs fail? By how much?   |
| Component refactor / migration | Grep tripwire tests (`chrome-token-migration.test.ts`-style) against proposed file list. Confirm MIGRATED_FILES entries.                                                          | Does the wave reach the tripwire? Any files miss the registration?    |
| Database migration             | `npm run lint:migrations` (Squawk) dry-run against proposed SQL                                                                                                                   | Squawk-clean? Which rules fire?                                       |
| Auth / token / permission      | Caller graph via grep — list every consumer of touched API surface                                                                                                                | What public contracts shift? Any external clients (extensions, PATs)? |
| Performance-sensitive code     | Baseline measurement before change (existing perf test or one-shot benchmark)                                                                                                     | What is the floor we cannot regress past?                             |
| Test gap (any domain)          | Coverage check on touched files; compare to suite-wide coverage                                                                                                                   | Tests cover the change? Coverage drop indicates gap.                  |
| Documentation / PR body / config | Markdownlint dry-run, grep for stale references (project file inventory vs claimed inventory in doc), heading-hierarchy check, link integrity (`markdown-link-check`), config validator dry-run (`eslint --print-config`, `gh workflow run --dry`) | Doc claims match current state? Stale references remain? Config parses + downstream consumers read it? |

Plan runs the check, captures the output, cites it. NEVER substitute judgment for unrun checks.

### When no mechanized check applies

Some waves don't match any domain above — PR body refresh, README rewrite, GitHub release notes, project-config tweaks, doc-only changes. These are real waves and plan still produces all six output sections, but mechanized predictions section becomes:

> No mechanized check applies — wave touches `<change kind>`, not source under contract-tested domain. Risk register relies on `judgment-required` items only.

This is an honest output, not a fallback. The other sections (scope, constraints, risk register, recovery options, exit criteria) still mechanize what they can — e.g. for PR body refresh, grep the body against the current deferred-items inventory; for README rewrite, run markdown lint; for config tweak, run config-schema validation.

## Output (hand to looper-build)

Structured brief, six sections:

1. **Wave scope**

   - Files touched (exact paths) OR change kind if no files touched (`PR body`, `GitHub release`, `external config`, `documentation`)
   - Regions within file (line ranges or function names) when narrower than whole-file
   - Blast radius estimate. For code waves: files + lines + downstream consumers. For non-file waves: user-visible impact surface (e.g. "PR description on github.com — visible to reviewers + repo browsers", "release notes — visible on releases page + automated changelog feeds").

2. **Constraints (cited)**

   - Each constraint = one line: `RULE — SOURCE (file:line or URL)`. No paraphrase, cite original
   - Example: `state-pair CVD JND >= 10 (delta-E 2000) — bundles.distinguishability.test.ts:42`

3. **Mechanized predictions**

   - For each check run, output verdict + numeric proof
   - Example: `bundle-contrast on `apollo-10-1-2` dark mount-border vs mount-bg: 1.82:1 (FAIL, needs 3:1). Recovery A: lift bg lum by 0.04 -> 3.12:1 (PASS).`
   - Cite source file + line for every threshold

4. **Risk register**

   - What can still go wrong that mechanized checks cannot catch (rendering-context judgment, novel palette, brand-locked constraint)
   - Severity tag: `mechanizable-residual` (a previously-deferred check could catch this; queue it) vs `judgment-required` (escalate to specialist)

5. **Recovery options pre-staged**

   - For each predicted failure, primary fix + fallback. Build picks one; no improvisation
   - Example: `state-pair info vs success collapse under deuteranopia. Option A: shift info lum +0.06. Option B: bring shape redundancy in consuming component`

6. **Exit criteria**
   - Concrete: "wave done when N files migrated, contract tests green, no new lint warnings"
   - Used by verify + review to confirm "wave done" objectively

## Escalation to specialist (the residual path)

Mechanizable check covers most cases. Some categories ALWAYS escalate even when mechanized passes:

- **Brand-locked palette decisions** (e.g. landing page hardcoded white-on-navy). Mechanized check tells you contrast value; only specialist tells you whether palette can shift.
- **Novel palette / new theme.** No historical baseline for delta-E sanity; specialist must vet.
- **Rendering-context mismatch.** Mechanized check assumes import location = host bundle. Shared components render under DIFFERENT host bundle than import directory. Plan flags suspicion; specialist judges.
- **Public API contract changes** (auth surface, extension API). Mechanized check catches caller list; specialist reviews threat model.

When escalation needed, plan emits one line per gate: `ESCALATE: <gate name> — <input to pass> — <output looper-build needs to resume>`. Orchestrator routes; build stops until orchestrator returns the gate output.

## What plan does NOT do

- Plan does NOT pick the final values. Recovery options offered; build decides which to apply (within constraints).
- Plan does NOT write code. Mechanized checks read existing files + dry-run tests. No `Edit` / `Write` to source.
- Plan does NOT replace specialist for judgment-required residuals. Mechanized checks cover deterministic surface; specialists own the rest.
- Plan does NOT re-research. If a constraint missing, send back to research, do not invent it.

## Stop conditions

- Research output ambiguous on critical decision (target files, expected behavior) → STOP. Send back to research.
- Mechanized check infra missing (test file does not exist, culori not installed, Squawk config absent) → STOP. Surface infra gap to orchestrator BEFORE proceeding.
- All recovery options fail their own predictions → STOP. Escalate to user — palette / architecture decision needed, not a wave.
- Wave scope exceeds research-stated blast radius by 2x or more → STOP. Scope challenge per memory `[[feedback-refactor-staging]]`.
- Specialist gate required AND orchestrator unable to invoke (Task tool absent) → STOP. Hand-off report, do not pretend gate ran. Per memory `[[feedback-task-tool-availability]]`.

## Voice + style

Match existing looper skill voice. Cite, do not paraphrase. Numbers, not vibes. When a constraint comes from a file, cite `file:line`. When from a URL, cite URL. When from project memory, cite `[[memory-name]]`.

Brief MUST be re-readable by a future loop with no prior context. Self-contained.
