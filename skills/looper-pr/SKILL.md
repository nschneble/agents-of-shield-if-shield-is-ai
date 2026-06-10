---
name: looper-pr
description: Create draft PRs for bugfixes and feature implementations. Trigger when the user says "draft a PR" or "let's publish these changes."
---

Final step. Create draft PR. Refuse if pre-flight fail.

## Pre-flight (REQUIRED)

Before open PR, confirm:

1. `looper-verify` produced PASS on all acceptance criteria
2. `looper-review` produced `ship` or `fix-blockers-then-ship` with NO blockers remaining
3. `format`, `lint`, `test`, `build` all green (or project equivalent)
4. No `cat > file` or other Bash-bypass write evidence in diff (`git log` and `git diff` should match — look for files created without normal write-path signal)
5. `git status` clean of untracked stray files (lunchlady-style scorecard.png leaks per memory `feedback-lunchlady-scorecard-leak`)

Any pre-flight fail → STOP. Tell orchestrator what blocking.

## PR body format

Read recent merged PRs first to match codebase style:

```
gh pr list --limit 5 --state merged
```

Clear pattern emerge → emulate. Else default to:

```
[fix|feat|chore] Short title (under 70 chars)

## Summary
- 1–3 bullets on what changed and why

## What changed
- Substantive change 1 (file or area)
- Substantive change 2
- ...

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

## Create as DRAFT and assign the user

PRs from looper = drafts, not ready-for-review. User decide when flip. Always assign authenticated user (`@me`) so PR show in dashboard. Use:

```
gh pr create --draft --assignee @me --title "..." --body "..."
```

Pass body via HEREDOC to preserve format. Creating PR without `--assignee` for any reason → immediately follow with:

```
gh pr edit <number> --add-assignee @me
```

## What looper-pr does NOT do

- Does NOT auto-flip to ready-for-review
- Does NOT request specific reviewers (user assigns)
- Does NOT push to main / merge / close issues — only opens PR
- Does NOT skip pre-flight even if user in hurry. Pre-flight exist to catch loops that snuck past verify + review.
- Does NOT skip assigning `@me`. Draft PR without assignee disappear from dashboard, easy to forget.
