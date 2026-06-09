---
name: looper-pr
description: Create draft PRs for bugfixes and feature implementations. Trigger when the user says "draft a PR" or "let's publish these changes."
---

Final step. Create a draft PR. Refuse if pre-flight fails.

## Pre-flight (REQUIRED)

Before opening the PR, confirm:

1. `looper-verify` produced PASS on all acceptance criteria
2. `looper-review` produced `ship` or `fix-blockers-then-ship` with NO blockers remaining
3. `format`, `lint`, `test`, `build` all green (or project equivalent)
4. No `cat > file` or other Bash-bypass write evidence in the diff (`git log` and `git diff` should match — look for files created without the normal write-path signal)
5. `git status` is clean of untracked stray files (lunchlady-style scorecard.png leaks per memory `feedback-lunchlady-scorecard-leak`)

If any pre-flight check fails → STOP. Tell orchestrator what's blocking.

## PR body format

Read recent merged PRs first to match codebase style:

```
gh pr list --limit 5 --state merged
```

If a clear pattern emerges, emulate it. If not, default to:

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

- Link any ticket (Jira, Linear, GitHub issue) at the very top of the body
- Attach screenshots for UI changes when available (refer to verify's browser run)
- Include before/after for visual changes
- Document any deferred work explicitly — don't hide it

## Create as DRAFT and assign the user

PRs created by looper are drafts, not ready-for-review. User decides when to flip. Always assign the authenticated user (`@me`) so the PR shows up in their dashboard. Use:

```
gh pr create --draft --assignee @me --title "..." --body "..."
```

Pass the body via HEREDOC to preserve formatting. If creating the PR without `--assignee` for any reason, immediately follow with:

```
gh pr edit <number> --add-assignee @me
```

## What looper-pr does NOT do

- Does NOT auto-flip to ready-for-review
- Does NOT request specific reviewers (user assigns)
- Does NOT push to main / merge / close issues — only opens the PR
- Does NOT skip the pre-flight even if the user is in a hurry. The pre-flight exists to catch the loops that snuck past verify + review.
- Does NOT skip assigning `@me`. A draft PR without an assignee disappears from the user's dashboard and is easy to forget.
