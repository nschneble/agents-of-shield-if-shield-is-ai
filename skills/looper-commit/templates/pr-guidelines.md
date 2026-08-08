# PR body guidelines

How to write and update a PR description. The diff is there. The body text
orients the reviewer. It does not re-narrate changes. Lean is best.

## Writing

- Lead with WHY in 1–2 sentences. No preamble
- Bullets over paragraphs. One line per substantive change
- Never restate the diff line-by-line. Annotations answer what/why/gotchas
- Link the ticket (Jira, GitHub issue, etc) at the top
- Test plan is checkboxes, not prose
- No empty sections
- `## Additional notes` is off by default. Add it only for a fact the reviewer
  needs and cannot get from the diff, the tests, or CI
  - Qualifies: an approach tried and rejected for a reason the diff can't show,
    a manual step the merge requires, a constraint outside the repo
  - Never: test counts, verification or lint/build status, deferred work,
    rationale the summary carries, restating the bullets
  - Budget: 4 sentences. Longer means it belongs in the code or a doc

## Budgets

- Summary: ≤ 2 sentences
- Changed: 1 line per change, substantive changes only
- Optional structured recap
  - 2–4 key files
  - Each hunk < 40 lines
  - Skip for small or obvious diffs

## Voice + attribution

- Run the assembled body through `the-ghostwriter` before submitting
  - Sentence case
  - No em-dashes (`—`)
  - No slop vocabulary (`leverage`, `seamless`, `robust`, etc)
  - Real `…` not `...`
- No AI-attribution trailers
  - No `Co-Authored-By`
  - No "Generated with Claude Code"
  - No other markers
