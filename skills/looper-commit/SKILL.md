---
name: looper-commit
description: Final step of every wave. Always commits any code/doc changes. Auto-detects PR state — if branch has existing PR, just commits; if no existing PR, creates draft assigned `@me`. Trigger when the user says "commit this wave", "finalize this wave", "create the PR", or "update the existing PR with this work".
---

Last step. Always commits. Conditionally creates PR.

Renamed from `looper-pr` in framework v1.2. Old name tied to PR creation; reality: commit is load-bearing action, PR creation only happens when branch has no existing PR. Skipping commit because no new PR needed was spec bug that lost work in transit.

## When this runs

Every wave runs this as final step. Two paths:

- **Code wave / doc wave** — staged or unstaged changes exist → commit step runs → PR detection runs
- **External-state wave** (PR body refresh, GitHub release update, manual baseline approval handoff) — working tree clean → commit step SKIPPED but PR detection still runs (confirms PR exists for external change context)

## Pre-flight (REQUIRED)

Before commit, confirm:

1. `looper-verify` produced PASS on all acceptance criteria
2. `looper-review` produced `ship` or `fix-blockers-then-ship` with NO blockers remaining
3. `format`, `lint`, `test`, `build` all green (or project equivalent; skip irrelevant ones for non-code waves per `looper-build` SKILL.md branching)
4. No `cat > file` or other Bash-bypass write evidence in diff (`git log` and `git diff` should match — look for files created without normal write-path signal)
5. `git status` clean of untracked stray files (lunchlady-style scorecard.png leaks per memory `feedback-lunchlady-scorecard-leak`)

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
   - `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>` line
4. Commit:
   ```
   git commit -m "$(cat <<'EOF'
   <message body>

   Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
   EOF
   )"
   ```
5. Verify commit landed:
   ```
   git log -1 --format=%H
   ```
   and capture hash for hand-back.

If commit fails (pre-commit hook failure, signing failure, etc), STOP — fix underlying issue, re-stage, create NEW commit. NEVER amend. NEVER bypass hooks (`--no-verify`, `--no-gpg-sign`, etc).

## Step 2: PR detection

Check if current branch has tracked PR:

```
gh pr view --json number,url,state 2>/dev/null
```

Three cases:

| State                  | Action                                                                                          |
| ---------------------- | ----------------------------------------------------------------------------------------------- |
| Has open / draft PR    | Done. Log `Wave commits to PR #N (existing)` with URL. No new PR.                               |
| Has merged / closed PR | Treat as "no PR" — proceed to Step 3 (closed PR may be unrelated history on this branch)        |
| No PR found            | Proceed to Step 3                                                                               |

## Step 3: Create draft PR (only if no existing)

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

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

- Link any ticket (Jira, Linear, GitHub issue) at top of body
- Attach screenshots for UI changes when available (refer to verify's browser run)
- Include before/after for visual changes
- Document deferred work explicit — don't hide

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

## Push behavior

Default: local commit only, no push. Orchestrator decides push timing per its protocol.

If brief includes explicit `target.push: true`:
- Branch tracks origin: `git push`
- Branch untracked: `git push -u origin <branch>`

If push fails (permissions, divergence), STOP — surface to orchestrator. Do NOT `--force`.

## What looper-commit does NOT do

- Does NOT auto-flip draft → ready-for-review (user's call)
- Does NOT request specific reviewers (user assigns)
- Does NOT push to main / merge / close issues
- Does NOT skip pre-flight even if user in hurry. Pre-flight catches loops that snuck past verify + review.
- Does NOT skip assigning `@me`. Draft PR without assignee disappears from dashboard, easy to forget.
- Does NOT amend commits. Pre-commit hook failure → fix + new commit, never amend.
- Does NOT bypass hooks (no `--no-verify`, no `--no-gpg-sign`).
- Does NOT auto-push. Push is orchestrator's call.