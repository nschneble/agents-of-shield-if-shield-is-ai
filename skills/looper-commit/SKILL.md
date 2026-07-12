---
name: looper-commit
description: Final step of every wave. Always commits any code/doc changes. Auto-detects PR state: if branch has existing PR, just commits; if no existing PR, creates draft assigned `@me`. Trigger when the user says "commit this wave", "finalize this wave", "create the PR", or "update the existing PR with this work".
---

Last step. Always commits. Conditionally creates PR.

Commit is the load-bearing action; PR creation happens only when the branch has no existing PR. Skipping the commit because no new PR was needed once lost work in transit — commit always runs.

## When this runs

Every wave runs this as final step. Two paths:

- **Code wave / doc wave**: staged or unstaged changes exist → commit step runs → PR detection runs
- **External-state wave** (PR body refresh, GitHub release update, manual baseline approval handoff): working tree clean → commit step SKIPPED but PR detection still runs (confirms PR exists for external change context)

## Pre-flight (REQUIRED)

Before commit, confirm:

1. `looper-verify` produced PASS on all acceptance criteria
2. `looper-review` produced `ship` or `fix-blockers-then-ship` with NO blockers remaining
3. `format`, `lint`, `test`, `build` all green (or project equivalent; skip irrelevant ones for non-code waves per `looper-build` SKILL.md branching)
4. No `cat > file` or other Bash-bypass write evidence in diff (`git log` and `git diff` should match; look for files created without normal write-path signal)
5. `git status` clean of untracked stray files (e.g. tool-generated scorecard.png leaks per memory `feedback-lunchlady-scorecard-leak`)

Any pre-flight fail → STOP. Tell orchestrator what blocking.

## Step 1: Commit

Check working tree:

```
git status --porcelain
```

Empty output → skip to Step 2 (external-state wave; commit not applicable). Log "no commit needed for external-state wave."

Non-empty output → commit:

1. Read recent commits for message style match:
   ```
   git log --oneline -5
   ```
2. Stage SPECIFIC files (no `-A`, no `-u`):
   ```
   git add <path1> <path2> ...
   ```
3. Compose message:
   - Title under 70 chars matching project convention from recent commits
   - HEREDOC body for multi-line
4. Commit:

   ```
   git commit -m "$(cat <<'EOF'
   <message body>
   EOF
   )"
   ```

5. Verify commit landed:
   ```
   git log -1 --format=%H
   ```
   and capture hash for hand-back.

If commit fails (pre-commit hook failure, signing failure, etc), STOP; fix underlying issue, re-stage, create NEW commit. NEVER amend. NEVER bypass hooks (`--no-verify`, `--no-gpg-sign`, etc).

## Step 2: PR detection

Check if this branch has a tracked PR. Query by explicit branch, not `gh pr view` — `gh pr view` only reads the *current* branch and errors noisily when none exists, which is fragile in detached or non-current-branch contexts:

```
gh pr list --head <branch> --state all --json number,url,state,isDraft
```

Empty array → no PR. Non-empty → read `state` of the first entry.

Three cases:

| State                  | Action                                                                                  |
| ---------------------- | --------------------------------------------------------------------------------------- |
| Has open / draft PR    | Done. Log `Wave commits to PR #N (existing)` with URL. No new PR.                       |
| Has merged / closed PR | Treat as "no PR"; proceed to Step 3 (closed PR may be unrelated history on this branch) |
| No PR found            | Proceed to Step 3                                                                       |

## Step 3: Create draft PR (only if no existing)

> **Brief semantics.** A brief that says "don't flip to ready-for-review" does NOT suppress this step — draft *creation* and the draft→ready *flip* are different actions (see `## What looper-commit does NOT do`). Only an explicit `pr: skip` directive suppresses creation. In an orchestrated multi-wave run the brief carries `pr: create-on-wave-1` (this step runs, branch must be pushed first) or `pr: existing #N` (Step 2 detects it → this step is skipped, commit lands in the existing PR). Never read "no new PR needed" out of a directive that only forbids the ready flip. See loop-de-looper `## PR lifecycle + push ownership`.

Read recent merged PRs to match codebase style:

```
gh pr list --limit 5 --state merged
```

Clear pattern → emulate. Else default to:

```
[fix|feat|chore] Short title (under 70 chars)

## Summary
- 1–3 bullets on what changed and why

## What changed
- Substantive change 1 (file or area)
- Substantive change 2

## Test plan
- [ ] Manual repro / verification step
- [ ] Edge case 1
- [ ] Automated test coverage notes

## Notes for reviewer
- Anything non-obvious in the diff
- Any known issues consciously deferred (with reason)
- Any architectural decisions worth a second pair of eyes
```

- Link any ticket (Jira, Linear, GitHub issue) at top of body
- Attach screenshots for UI changes when available (refer to verify's browser run) — and add the structured recap's UI before/after block (see `## Structured recap (PR-body section)`)
- Include before/after for visual changes — the ASCII wireframe in `## Structured recap (PR-body section)` is the dependency-free default
- Document deferred work explicit; don't hide

> **Recap timing.** In an orchestrated multi-wave run the structured recap is emitted by the TERMINAL PR-body refresh (`loop-de-looper` Step 4), NOT at wave-1 creation — so a wave-1 executor does NOT build it here from a partial diff. A standalone single-commit PR (no orchestrator, whole diff already present) can include it directly.

Create as DRAFT, assign `@me`:

```
gh pr create --draft --assignee @me --title "..." --body "$(cat <<'EOF'
...
EOF
)"
```

Creating without `--assignee` for any reason → immediately follow with:

```
gh pr edit <number> --add-assignee @me
```

Pass body via HEREDOC to preserve format.

## Structured recap (PR-body section)

The emitted `## Structured recap` block in the PR body gives the reviewer the *shape* of the diff before they read it. Dependency-free reimplementation of Builder.io's `visual-recap` taxonomy — same review-acceleration value, PLAIN GitHub markdown, NO hosted / MCP tool (standing directive: no third-party hosted-tool reliance). Stands on its own; a reader who never saw `visual-recap` needs nothing else.

This section defines the FORMAT only. WHEN a recap is emitted (which waves, the UI-glob that gates the wireframe block) is decided upstream — not here.

Composed of three content sub-blocks, rendered in order — plus a skip rule (a guard that suppresses the whole section, not a fourth block that gets rendered):

### 1. File-tree with change flags

The changed files as an indented tree, one flag per entry. Flags come straight from `git diff --name-status` (`A`/`M`/`D`/`R`):

```
skills/
  looper-commit/
    SKILL.md          [M]
  looper-recap/
    SKILL.md          [A]
src/
  lib/
    legacy-pad.ts     [D]
    format.ts         [R]  (was fmt.ts)
```

Legend: `[A]` added · `[M]` modified · `[D]` removed · `[R]` renamed. One tree, whole run — this is the map the other blocks index into.

### 2. Collapsed `<details>` diff hunks with annotations

For each load-bearing changed file, a collapsible block GitHub renders natively — collapsed by default so the PR body stays scannable. Budget roughly 3–8 key files; skip pure mechanical churn. Each block holds a REAL diff excerpt (fenced ` ```diff `) plus a few high-signal annotation notes:

````markdown
<details>
<summary><code>src/lib/format.ts</code> — drop the legacy pad() path</summary>

```diff
@@ -12,7 +12,7 @@ export function format(x) {
-  return pad(x, 2)
+  return x.toString().padStart(2, "0")
```

- `pad()` is now dead — removed in `legacy-pad.ts` (see tree).
- Identical output for x < 100; diverges above (old path truncated).
</details>
````

Keep each excerpt focused (~<150 lines) — the load-bearing hunk, not the whole file. Annotations answer what changed, why, and any gotcha — not a line-by-line restatement of the diff.

### 3. UI before/after ASCII wireframe + a11y risk (UI changes only)

ONLY when the change touches rendered UI: a plain-text before/after sketch of the visible delta, plus a short call-out of the accessibility-relevant risk. The include decision is made upstream (the UI-glob); here we define the shape.

```
Before                       After
┌──────────────┐             ┌──────────────┐
│  [ Submit ]  │             │  [ Submit ▸ ]│
└──────────────┘             └──────────────┘

a11y risk: the new ▸ glyph is decorative — needs aria-hidden, else the
button's accessible name reads "Submit right-pointing triangle".
```

If this block is included, the a11y call-out is mandatory and specific — name the actual risk (contrast, accessible-name, focus order, motion), never a generic "check a11y".

### Small-diff skip (guard, not a rendered block)

A genuinely tiny change — one file, a handful of obvious lines, no behavioural subtlety, no UI delta — gets NO structured recap. It reviews faster as the raw diff; a recap is pure noise on it. Skip the whole section, don't emit an empty one. When genuinely unsure, include it — the cost of a recap on a small diff is low; the cost of omitting it on a subtle one is a missed review.

### Grounding + secret redaction (every block)

- Build the structural blocks MECHANICALLY from the real whole-run diff (`git diff <run-base>..HEAD`, `git diff --name-status`). `<run-base>` is a NAMED token bound upstream, NOT derived here: an orchestrated run's `loop-de-looper` binds it to `<wave1>^`; a standalone single-commit PR uses its own base (e.g. the branch point). Tree, flags, hunks are byte-exact excerpts — never invented or inferred. The UI wireframe (block 3) is the ONE exception: a diff-constrained good-faith RECONSTRUCTION, still never inventing an element the diff doesn't carry. When the diff doesn't carry a fact, leave it out; anything beyond the diff (intent, downstream impact) stated anyway → mark it `inferred:`.
- NEVER transcribe secrets. Redact API keys, tokens, passwords, and `.env` values in any block — `sk-•••`, `ghp_•••`, `<redacted>`. If a hunk's only content is a secret rotation, describe it ("rotated `STRIPE_KEY`") without reproducing the value.

## Push behavior

Default: local commit only, no push. Orchestrator decides push timing per its protocol.

If brief includes explicit `target.push: true`:

- Branch tracks origin: `git push`
- Branch untracked: `git push -u origin <branch>`

If push fails (permissions, divergence), STOP; surface to orchestrator. Do NOT `--force`.

## What looper-commit does NOT do

- Does NOT auto-flip draft → ready-for-review (user's call)
- Does NOT request specific reviewers (user assigns)
- Does NOT push to main / merge / close issues
- Does NOT skip pre-flight even if user in hurry. Pre-flight catches loops that snuck past verify + review.
- Does NOT skip assigning `@me`. Draft PR without assignee disappears from dashboard, easy to forget.
- Does NOT amend commits. Pre-commit hook failure → fix + new commit, never amend.
- Does NOT bypass hooks (no `--no-verify`, no `--no-gpg-sign`).
- Does NOT auto-push. Push is orchestrator's call.
- Does NOT decide WHEN the structured recap fires, or gate on it — defines the FORMAT only; timing is `loop-de-looper` Step 4's call.
