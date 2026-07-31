# Default PR body template

Fallback when the target repo has no `.github/PULL_REQUEST_TEMPLATE.md` and
recently merged PRs show no clear house style. Step 3 in SKILL.md.

Keep it lean. `templates/pr-guidelines.md` governs brevity + voice. Copy
the fenced block + keep the surrounding Step 3 rules.

## Step 3: Create draft PR (only if no existing)

```markdown
[Bugfix|Feature|Chore]: Short title (< 70 chars)

Why this change, in 1–2 sentences.

**Changed:**

- Substantive change 1 (file or area)
- Substantive change 2
```

Add an `## Additional notes` section when the diff hides something
non-obvious.
