# Looper Declutter — design rationale + decision log

The human dossier behind `skills/looper-declutter/SKILL.md`. The SKILL.md is the executable spec; this file records WHY the non-obvious choices were made, so a future edit doesn't re-litigate a settled call.

## Why it exists

Comment discipline was already fully owned — `the-chronicler` (mechanics), `the-ghostwriter` (voice/de-slop), `the-improver` (delete-restate) — but only enforced REACTIVELY, inside a `looper-review` crew pass over the pending diff. That covers new bloat a change introduces. It never reaches bloat that predates the change: a file whose comments were over-narrated long ago is never re-touched unless a diff happens to cross those lines.

`looper-declutter` is the proactive whole-repo sweep that closes the gap — exactly the relationship `looper-defend` has to `security-review`/`the-diamantaire`: they review the pending diff, defend hunts the whole repo. Declutter : comment-bloat :: defend : security.

The trigger for building it: a real target repo (Linklater) accumulated well over a thousand comment-bloat candidates the reactive crew had never seen.

## Governing principle: declutter PROPOSES, human DISPOSES

A comment is a judgment call, not a mechanical fact. An autonomous pass that auto-rewrote every flagged comment would flatten a deliberate GOTCHA, lowercase a proper noun, or truncate the one line that earned its length. So scan/triage/report run read-only and automatically; every snip is a checkbox that applies only after a human ticks it and runs `/looper-declutter apply`. There is NO auto-apply class — the one place this differs from defend, which auto-lands a dependency CVE bump. A dep bump has a mechanical oracle (suite stays green, diff confined to the lockfile); a comment trim has none, so it never skips the tick.

## Why these mechanisms (the non-obvious choices)

- **Reuse the owners; never duplicate them.** Four of the five requested rules (75-char wrap, lowercase `//`, WHY-only depth, the humanizer/de-slop) already live in `the-chronicler` and `the-ghostwriter`, which explicitly cross-reference each other to avoid a double pass. Declutter re-encoding any of them would fork the source of truth. So it contributes only two genuinely new things — a mechanical detector and the routing orchestration — and applies the owners' rules by reference. If an owner's rule changes, declutter inherits it for free.
- **The detector is self-contained.** `scripts/doc-bloat-scan.sh` is pure bash + awk + grep, no third-party linter, no tokenizer, no hosted tool (`[[no-third-party-hosted-tool-reliance]]`) — the same discipline as `scripts/custodian-skill-lint.sh`. It emits JSONL candidates and never edits or gates.
- **Full-line comments only, C-style only (v1).** The detector treats a line as a comment only when the trimmed line STARTS with `//` or `/*`. That deliberately ignores trailing end-of-line comments and `#`-comment languages — and in exchange, a `//` inside a string or a `https://` URL is never mis-read as a comment. Recall precision beats recall breadth for a propose-only finder; the human-disposes gate is where the rest is caught. Extending to trailing comments and `#`-languages is future scope.
- **Snips group one wave per file.** All of a file's ticked snips are one cohesive, behavior-preserving doc wave, not one wave per comment — cheaper and more reviewable.
- **Comment-only, verified.** A snip edits comment text only; `looper-verify` confirms no non-comment byte moved and the suite stays green, else revert. This is the invariant that lets an autonomous trim be safe.
- **Repo-scoped, not cross-repo.** Declutter hunts the repo it is run in, like defend. Cross-repo reach is `looper-custodian`'s explicit-list domain; folding declutter into it is deferred, not designed out.

## Decision log

- **2026-07-30 — new skill vs. fold into existing surfaces.** Chose a standalone `looper-defend`-style skill over wiring the detector into `looper-custodian` Phase B + a `looper-review` enhancement. Rationale: the whole-repo, on-demand, `apply`/`--dry-run` shape is exactly defend's, and it gives a bloated repo a first-class entry point the reactive crew can't offer. A custodian Phase-B hook to schedule declutter across the repo list stays open as future scope.
- **2026-07-30 — no auto-apply class.** Considered mirroring defend's narrow auto-apply (dep-bump) for the most mechanical kind (`capitalized-slash`, `over-75`). Rejected: even lowercasing a first word can corrupt a proper noun, and truncation can drop meaning. Every snip needs a tick.
- **2026-07-30 — 75 chars, break at column 76.** The spec's "76 chars" is the cursor position at the wrap, i.e. 75 chars of content. This already matches `the-chronicler.md`'s 75-char hard limit; the detector's `over-75` kind and the global CLAUDE.md rule express the same number. No conflicting constant introduced.
- **2026-07-30 — dedupe by comment, not by kind.** One comment can trip several detector kinds; triage groups them into a single `D-<n>` so a reviewer sees one proposal per comment, not four.
