# Default PR body template

Fallback when the target repo has no `.github/PULL_REQUEST_TEMPLATE.md` and recent merged PRs show no clear house style (SKILL.md `## Step 3: Create draft PR (only if no existing)`). Keep it lean; `templates/pr-guidelines.md` governs brevity + voice. Copy the fenced block; keep the surrounding Step 3 rules (ticket link, screenshots, HEREDOC, draft + `@me`).

```
[fix|feat|chore] Short title (under 70 chars)

## Summary
Why this change, in 1–2 sentences.

## What changed
- Substantive change 1 (file or area)
- Substantive change 2

## Test plan
- [ ] How this was verified
```

Add a `## Notes for reviewer` section ONLY when the diff hides something non-obvious: a consciously deferred call, or an architectural decision worth a second pair of eyes. No empty sections; the diff is right there.
