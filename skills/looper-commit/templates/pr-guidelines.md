# PR body guidelines

How to write AND update a PR description. The diff is right there; the body orients the reviewer, it does not re-narrate the change. Lean beats complete.

## Writing

- Lead with WHY in 1–2 sentences. Skip the preamble
- Bullets over paragraphs. One line per substantive change
- Never restate the diff line-by-line. Annotations answer what / why / gotcha
- Link the ticket (Jira, Linear, GitHub issue) at the top
- Test plan is checkboxes, not prose
- No empty sections. Drop `## Notes for reviewer` unless something is genuinely non-obvious

## Budgets

- Summary: ≤ 2 sentences
- What changed: 1 line per change, substantive changes only (skip mechanical churn)
- Structured recap (optional, gated): 2–4 key files, each hunk ~< 40 lines. A small or obvious diff → skip it (SKILL.md `## Structured recap (PR-body section)` → small-diff skip)

## Voice + attribution

- Run the assembled body through `the-ghostwriter` before submitting: sentence case, no em-dash (`—`), no slop vocabulary (`leverage`, `seamless`, `robust`, `delve`…), real `…` not `...`, straight quotes
- No AI-attribution trailer: no `Co-Authored-By`, no "Generated with Claude Code", no other marker
