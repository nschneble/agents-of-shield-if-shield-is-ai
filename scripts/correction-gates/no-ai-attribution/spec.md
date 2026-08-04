---
id: no-ai-attribution
title: No AI-attribution markers in commits or PR bodies
enabled: true
exec: ./gate.sh --dir "$CG_DIR" --range "$CG_RANGE"
needs: [dir, range]
provenance:
  memories:
    - no-ai-attribution
  claude_md: "user-global CLAUDE.md and repo convention — no Co-Authored-By trailer, no Generated-with footer, no other marker"
  correction: "No AI-attribution markers anywhere in this repo: no Co-Authored-By Claude trailer on commits, no Generated with Claude Code footer on PR bodies, no other marker."
  origin: "asked to strip the footer from PR #8; the repo dropped the trailer requirement in commit 275d15a; the memory is itself a merge of two re-violated notes (custodian B-merge-1, issue #29)"
asserts: "No banned AI-attribution tell appears in the scanned commit message(s) or an optional staged PR body."
---

# no-ai-attribution

The **second** registry entry, chosen deliberately as a different
correction CLASS from format-scope — commit/PR-surface hygiene, not file
formatting — so the registry is demonstrably generic, not format-scope
compiled twice. It compiles the recorded correction in memory
`no-ai-attribution` (and the user-global CLAUDE.md rule): **no
AI-attribution markers anywhere** — no `Co-Authored-By: Claude` trailer,
no `Generated with Claude Code` footer, no other tell. It re-violated
before it was a rule (the footer had to be stripped from PR #8; the memory
is a merge of two separate notes), which is exactly the recall-only pattern
a compiled gate forecloses.

## What it asserts

`gate.sh` FAILS if any of these tells appear in the scanned commit
message(s) or an optional PR-body file:

- a `Co-Authored-By: Claude ...` (or `@anthropic`) trailer
- a `Generated with [Claude Code]` footer, with or without the emoji
- a `claude.ai/code` link

## Execution and position

The runner threads `$CG_DIR` and `$CG_RANGE`. This is a COMMIT/PR-surface
gate: it reads git history (and, via `--body`, a staged PR body), so its
natural slot is commit/PR time (`looper-commit`), not the working-tree
pre-commit slot format-scope uses. `--range` is that position — a bare ref
scans one commit (default `HEAD`, the commit a wave is about to add); an
`A..B` range scans the span. That the two entries run at DIFFERENT points
is the "compare-ref must be a parameter, not baked in" generalization made
concrete.
