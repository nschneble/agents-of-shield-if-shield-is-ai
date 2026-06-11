---
name: looper-plan
description: Produce tactical brief for a single wave between research and build. Trigger when the user says "plan this wave", "spec the wave", or "what's the brief for this change?"
---

Slot between research and build. Convert research constraints into wave-specific contract: files, deterministic predictions, recovery options pre-staged, exit criteria. Mechanize parts of a11y-lead / security review / migration review that math, lint, or grep can answer. Escalate residual.

## Why plan exists

Research surface constraints abstract ("WCAG 1.4.11 needs 3:1 borders against bundle-bg"). Build need concrete ("for THIS wave, 4 token pairs touched, predicted contrast value each, 2 fail + recovery option each").

Without plan, build guess (surface palette right, miss contract-level math) or orchestrator invoke specialist subagent per wave (slow, block autonomy). Plan absorb deterministic portion of specialist judgment into runnable check — keep loop autonomous unless real judgment need.

## Inputs

1. `looper-research` output (structured report)
2. Project CLAUDE.md + nested `.claude/CLAUDE.md`
3. Project memory at `~/.claude/projects/<project>/memory/`
4. PRD if exist (default `local/prds/<feature-slug>.md`, else memory `reference-prds`)
5. Current branch state — `git status`, `git diff HEAD`, recent commits in scope

## Mechanized contract checks (the big idea)

Each domain plan support, run deterministic checks BEFORE handoff to build. Each check answer yes/no with citations — no judgment, no vibes.

| Domain                           | Mechanized check                                                                                                                                                                                                                                   | What it answers                                                                                        |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Color tokens / contrast / CVD    | Dry-run contract tests (`bundles.contrast.test.ts`, `bundles.distinguishability.test.ts`) against proposed token values via culori. WCAG 1.4.3 / 1.4.11 / CVD distinguishability.                                                                  | Will proposed palette pass contract? Which pairs fail? By how much?                                    |
| Component refactor / migration   | Grep tripwire tests (`chrome-token-migration.test.ts`-style) against proposed file list. Confirm MIGRATED_FILES entries.                                                                                                                           | Does the wave reach the tripwire? Any files miss the registration?                                     |
| Database migration               | `npm run lint:migrations` (Squawk) dry-run against proposed SQL                                                                                                                                                                                    | Squawk-clean? Which rules fire?                                                                        |
| Auth / token / permission        | Caller graph via grep — list every consumer of touched API surface                                                                                                                                                                                 | What public contracts shift? Any external clients (extensions, PATs)?                                  |
| Performance-sensitive code       | Baseline measurement before change (existing perf test or one-shot benchmark)                                                                                                                                                                      | What is the floor we cannot regress past?                                                              |
| Test gap (any domain)            | Coverage check on touched files; compare to suite-wide coverage                                                                                                                                                                                    | Tests cover the change? Coverage drop indicates gap.                                                   |
| Documentation / PR body / config | Markdownlint dry-run, grep for stale references (project file inventory vs claimed inventory in doc), heading-hierarchy check, link integrity (`markdown-link-check`), config validator dry-run (`eslint --print-config`, `gh workflow run --dry`) | Doc claims match current state? Stale references remain? Config parses + downstream consumers read it? |

Plan run check, capture output, cite. NEVER substitute judgment for unrun checks.

### Grep authority: use `git grep`, not `grep -r`

Any mechanized check that involves "find every consumer of X" or "verify zero consumers of Y" MUST use `git grep`, not `grep -r --include="*.{ext1,ext2}"`. Reasons:

- Bash brace expansion does NOT fire inside quoted strings. `--include="*.{tsx,ts,html}"` passes the literal string `*.{tsx,ts,html}` to grep, which matches nothing — silently scoping the search to zero files and returning a false zero.
- `git grep` respects `.gitignore` automatically, skipping `node_modules`, `dist`, `.claude/worktrees/`, and other agent-spawned trees that pollute results.
- `git grep` defaults to ignoring binary files and respects the repo's normalization.

Pattern to use:

```
git grep -nE "var\(--TOKEN\b" -- 'apps/web/src/**/*.tsx' 'apps/web/src/**/*.ts' 'apps/web/index.html'
```

Multiple extensions via repeated pathspecs (single-quoted), not via brace expansion.

False-zero consumer claims have shipped broken retirement waves before — plan-stage STOP fires per `[[feedback-verify-upstream-gate-claims]]`, but the cheaper failsafe is to author the grep correctly in the first place. Mechanized predictions section MUST include the actual `git grep` command run + raw output, not paraphrased "verified zero consumers."

### When no mechanized check applies

Some waves no match any domain — PR body refresh, README rewrite, GitHub release notes, project-config tweaks, doc-only changes. Real waves, plan still produce all six output sections, but mechanized predictions section become:

> No mechanized check applies — wave touches `<change kind>`, not source under contract-tested domain. Risk register relies on `judgment-required` items only.

Honest output, not fallback. Other sections (scope, constraints, risk register, recovery options, exit criteria) still mechanize what can — e.g. PR body refresh, grep body against current deferred-items inventory; README rewrite, run markdown lint; config tweak, run config-schema validation.

## Output (hand to looper-build)

Structured brief, six sections:

1. **Wave scope**

   - Files touched (exact paths) OR change kind if no files touched (`PR body`, `GitHub release`, `external config`, `documentation`)
   - Regions within file (line ranges or function names) when narrower than whole-file
   - Blast radius estimate. Code waves: files + lines + downstream consumers. Non-file waves: user-visible impact surface (e.g. "PR description on github.com — visible to reviewers + repo browsers", "release notes — visible on releases page + automated changelog feeds").

2. **Constraints (cited)**

   - Each constraint = one line: `RULE — SOURCE (file:line or URL)`. No paraphrase, cite original
   - Example: `state-pair CVD JND >= 10 (delta-E 2000) — bundles.distinguishability.test.ts:42`

3. **Mechanized predictions**

   - Each check run, output verdict + numeric proof
   - Example: `bundle-contrast on `apollo-10-1-2` dark mount-border vs mount-bg: 1.82:1 (FAIL, needs 3:1). Recovery A: lift bg lum by 0.04 -> 3.12:1 (PASS).`
   - Cite source file + line every threshold

4. **Risk register**

   - What still go wrong that mechanized checks cannot catch (rendering-context judgment, novel palette, brand-locked constraint)
   - Severity tag: `mechanizable-residual` (previously-deferred check could catch this; queue) vs `judgment-required` (escalate to specialist)

5. **Recovery options pre-staged**

   - Each predicted failure, primary fix + fallback. Build pick one; no improvise
   - Example: `state-pair info vs success collapse under deuteranopia. Option A: shift info lum +0.06. Option B: bring shape redundancy in consuming component`

6. **Exit criteria**
   - Concrete: "wave done when N files migrated, contract tests green, no new lint warnings"
   - Used by verify + review to confirm "wave done" objectively

## Escalation to specialist (the residual path)

Mechanizable check cover most cases. Some categories ALWAYS escalate even when mechanized pass:

- **Brand-locked palette decisions** (e.g. landing page hardcoded white-on-navy). Mechanized check tell you contrast value; only specialist tell you whether palette can shift.
- **Novel palette / new theme.** No historical baseline for delta-E sanity; specialist must vet.
- **Rendering-context mismatch.** Mechanized check assume import location = host bundle. Shared components render under DIFFERENT host bundle than import directory. Plan flag suspicion; specialist judge.
- **Public API contract changes** (auth surface, extension API). Mechanized check catch caller list; specialist review threat model.

When escalation need, plan emit one line per gate: `ESCALATE: <gate name> — <input to pass> — <output looper-build needs to resume>`. Orchestrator route; build stop until orchestrator return gate output.

## What plan does NOT do

- Plan NOT pick final values. Recovery options offered; build decide which apply (within constraints).
- Plan NOT write code. Mechanized checks read existing files + dry-run tests. No `Edit` / `Write` to source.
- Plan NOT replace specialist for judgment-required residuals. Mechanized checks cover deterministic surface; specialists own rest.
- Plan NOT re-research. Constraint missing, send back to research, do not invent.

## Stop conditions

- Research output ambiguous on critical decision (target files, expected behavior) → STOP. Send back to research.
- Mechanized check infra missing (test file no exist, culori not installed, Squawk config absent) → STOP. Surface infra gap to orchestrator BEFORE proceed.
- All recovery options fail own predictions → STOP. Escalate to user — palette / architecture decision need, not wave.
- Wave scope exceed research-stated blast radius by 2x or more → STOP. Scope challenge per memory `[[feedback-refactor-staging]]`.
- Specialist gate required AND orchestrator unable to invoke (Task tool absent) → STOP. Hand-off report, do not pretend gate ran. Per memory `[[feedback-task-tool-availability]]`.

## Voice + style

Match existing looper skill voice. Cite, no paraphrase. Numbers, not vibes. Constraint from file, cite `file:line`. From URL, cite URL. From project memory, cite `[[memory-name]]`.

Brief MUST be re-readable by future loop with no prior context. Self-contained.
