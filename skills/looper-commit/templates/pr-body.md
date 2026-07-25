# Default PR body template

Fallback when recent merged PRs show no clear house style (SKILL.md `## Step 3: Create draft PR (only if no existing)`). Copy the fenced block; keep the surrounding Step 3 rules (ticket link, screenshots, HEREDOC, draft + `@me`).

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
