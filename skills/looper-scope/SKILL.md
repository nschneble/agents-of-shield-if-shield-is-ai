---
name: looper-scope
description: Decompose a raw goal into an ordered wave queue with termination criteria. Trigger when the user says "scope this work", "plan the waves", or hands a goal to the orchestrator that spans more than one loop.
---

Strategic queue producer. Entry point for multi-wave goal. Read goal + existing state, emit ordered list of candidate waves, set exit contract. Refuse vague goals; bounded scope is deliverable.

## Why scope exists

Single loop fix one bug or ship one feature increment. Goals like "finish theme refactor" or "harden auth" cross many loops. No scope = orchestrator can't terminate (queue infinite) + can't sequence (no dependency order). Scope produce queue Loop de Looper consume.

Scope distinct from plan: scope enumerate waves at goal-level granularity (one line per wave). Plan turn one of those into tactical brief. Different altitudes.

## Inputs

1. Raw goal (user input or orchestrator handoff)
2. Existing PR description (if updating existing PR, `gh pr view <number>` for body)
3. PRD if exist (default `local/prds/<feature-slug>.md`, else memory `reference-prds`)
4. Project memory at `~/.claude/projects/<project>/memory/`: read `MEMORY.md`, then any `project-*` entries hinting at "what's left"
5. Git state: branch, `git log --oneline main..HEAD`, `git status`
6. File inventory of relevant directories (e.g. for theme refactor, `apps/web/src/components/**` + `apps/web/src/theme/styles/**`)

## Goal classification (first move)

Classify goal before decompose. Classification determine decomposition strategy.

| Goal shape                   | Example                                                             | Decomposition strategy                                                                                                           |
| ---------------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| **Single-wave bugfix**       | "Fix auth race condition in login flow"                             | One wave. Scope still runs; sets exit criteria, flags if staging needed                                                          |
| **Feature increment**        | "Add MFA recovery codes"                                            | 1–3 waves usually. Decompose by sub-feature (gen, store, verify, UI)                                                             |
| **Multi-file refactor**      | "Migrate UserMenu to orbit-tier"                                    | One wave per cluster of co-touching files. Group by host-bundle context, not directory alone                                     |
| **Cross-cutting initiative** | "Finish the theme refactor", "Harden a11y AAA"                      | Many waves. Order by dependency + risk. Pilot-first per memory `[[feedback-refactor-staging]]`                                   |
| **Release-readiness**        | "Flip draft PR to ready-for-review", "Wrap up the auth refactor PR" | Small queue (1–3 waves), often doc-heavy. Explicitly enumerate human-gated tasks; they block completion but loops can't run them |
| **Open-ended**               | "Improve performance", "Clean up the codebase"                      | REFUSE. Surface to user: needs budget, regression baseline, definition of done                                                   |

Open-ended goals = refusal, not best-effort decomposition. Scope job = bounded queue, not infinite work.

## Decomposition rules

For non-refused goals, produce waves that satisfy:

1. **Cohesive.** Each wave = one coherent change single loop ship end-to-end.
2. **Verifiable independently.** Wave done = pass tests + builds + verify checks for that wave alone. No "wave A only makes sense after wave B+C ship."
3. **Bounded blast radius.** Aim 1–10 files per wave. Bigger = split. Smaller = consider merge with adjacent.
4. **Dependency-ordered.** Wave M block wave N → M first. Independent waves can run either order; scope pick risk-low-first.
5. **Risk-tagged.** Each wave get one of `low` (cleanup, no behavior change) / `medium` (refactor, contract tests catch) / `high` (palette / architecture / specialist needed).
6. **Pilot-first for cross-cutting.** First wave = simplest representative case, not most bespoke. Stress-test bespoke last. Per memory `[[feedback-refactor-staging]]`.

## Output

Eight sections:

1. **Goal restatement**

   - One sentence: what scope think user mean. User correction step before queue acted on.

2. **Classification**

   - One of rows from table above. State explicitly.

3. **Wave queue (ordered)**

   - One line per wave: `Wave N | <candidate>  | <scope> | risk: low/medium/high | depends on: <wave M | none>`
   - `<scope>` column accept either file count (`files ~K`) for code waves OR change kind for non-file waves (`PR body`, `GitHub release`, `external config`). Non-file waves are real waves and belong in queue.
   - Aim queue length ≤ 15. Longer = goal too broad, recommend split.

4. **Exit criteria**

   - Goal done when: <bulleted criteria>. Concrete + objective. Used by Loop de Looper to terminate.
   - Example: "goal done when all 12 candidate components migrated to bundle utilities, `chrome-token-migration.test.ts` MIGRATED_FILES list complete, no `--bg-elevated` / legacy flat tokens grep matches in migrated files."

5. **Required, not loopable**

   - Items REQUIRED for goal completion but loops can't execute (human approval, third-party action, manual baseline review, user decision). Each line: `<item>: not loopable because <reason>`.
   - Goal cannot complete until these clear. Loop de Looper must surface to user explicitly.
   - Empty section fine if goal fully loopable.

6. **Deferred to separate scope run**

   - Things that COULD be in scope but consciously excluded for now, will likely surface in future scope run. Each line cite reason: `<item>: deferred because <reason>`.
   - Prevent scope creep mid-loop; document conscious choices for future runs to pick up.
   - Deferring is not debt — it is holding the option. Naming a future candidate and NOT queuing it now preserves the choice to build it once the need is real (cheaper, better-informed) instead of guessing this run. Don't pad the queue with speculative waves to "save a future scope run"; the future run is cheap and runs with more information.

7. **Out of goal scope**

   - Things consciously excluded forever from this goal (different PR, different initiative, architectural decision out of scope). Each line: `<item>: out of scope because <reason>`.
   - Distinguish "will come back to" (deferred) from "won't come back to this goal" (out of scope).

8. **Open questions**
   - Anything scope cannot proceed on without user input. Each question one line. Suggest answer when scope has recommendation.

## What scope does NOT do

- Scope NOT produce wave-level briefs. Plan does that, per-wave.
- Scope NOT execute waves. Loop de Looper dispatch them.
- Scope NOT write code or change branch state. Read-only.
- Scope NOT re-classify mid-run. If goal shape change (user expand scope), scope re-run from top. No incremental patches.
- Scope NOT speculate on future waves. If goal completion reveal new candidates, that new scope run.

## Stop conditions

- Goal vague / open-ended (no budget, no definition of done) → STOP. Refuse, ask for bounds.
- No candidates found (goal already achieved per git state) → STOP. Report "goal already met", let user confirm.
- Decomposition produce > 15 waves → STOP. Recommend split into sub-goals; offer two or three natural break points.
- Candidates all `high` risk requiring same specialist gate → STOP. Group as specialist-pre-flighted sub-initiative, do not autonomous-loop.
- Goal conflicts with project rules (CLAUDE.md, PRD, memory) → STOP. Cite rule + ask user to reconcile.

## Pilot recommendation (cross-cutting goals)

For cross-cutting initiatives, scope MUST recommend pilot. Per memory `[[feedback-refactor-staging]]`:

- Pilot = simplest representative case (NOT most bespoke).
- One wave end-to-end before rollout. Surface architectural issues at low cost.
- Scope tag pilot wave explicitly: `Wave 1 (PILOT) | <candidate>  | files ~K | risk: medium | depends on: none`
- Rollout waves blocked by pilot completion in dependency column.

Skip pilot only when classification = single-wave bugfix or feature increment ≤ 2 waves.

## Voice + style

Match existing looper skill voice. Cite, don't paraphrase. When candidates derive from memory, PRD, or file inventory, cite source so user can verify. No "I think there might be" hedging; scope either know or refuse.

Queue MUST be re-readable by Loop de Looper with no prior context. Self-contained.
