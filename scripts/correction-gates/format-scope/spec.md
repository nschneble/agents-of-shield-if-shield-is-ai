---
id: format-scope
title: Scope prettier to the wave's touched files
enabled: true
exec: ./gate.sh --dir "$CG_DIR" --range "$CG_RANGE" --touched-from "$CG_TOUCHED_FILE"
needs: [dir, range, touched]
provenance:
  memories:
    - feedback-format-drift-not-wave-scope
    - feedback-format-glob-vs-prettier-check
  correction: "Scope prettier to the files the wave actually touched, never the full-tree npm run format; reformatting files outside the wave's scope is drift to revert."
  recurrence: "3 branches, >=2 redundant memories (issue #40 Part B, table B1)"
  pilot: "E-greenlight-1 (PR #41) — the first correction compiled to a gate"
asserts: "Every declared touched file is prettier-clean (A), and no out-of-scope file is left prettier-clean by a full-tree format or an undeclared edit (B)."
---

# format-scope

The recurring correction this gate compiles, re-learned as prose across
branches (memories `feedback-format-drift-not-wave-scope` and its
consolidated sibling `feedback-format-glob-vs-prettier-check`): **scope
prettier to the files the wave touched, never the full-tree `npm run
format`; reformatting files outside the wave's scope is drift to revert.**
Memory-only recall let it re-violate — the C1/C25 gap this registry closes.

## What it asserts

Given the wave's declared touched-file list, `gate.sh` FAILS on either
failure mode of a full-tree format:

- **A — touched-unclean.** A file the wave declared it touched is not
  prettier-clean, so the wave would ship unformatted scope.
- **B — out-of-scope clean change.** A file the wave changed but did NOT
  declare is prettier-clean — either a full-tree format reformatted it
  (drift) or it is a real edit the wave never declared. Both are out of
  scope; the fix is to declare it or revert it.

The out-of-glob carve-out holds: a touched file prettier cannot parse
(exit >=2) is a note, not a violation.

## Execution

The runner threads `$CG_DIR`, `$CG_RANGE`, and `$CG_TOUCHED_FILE` (see the
registry `README.md` wave-context contract). `--range` is the compare-ref
for the git-derived changed set — default `HEAD`, but a committed wave can
pass its own base so the check does not go dark post-commit.

The prettier binary comes from `$PRETTIER` / `--prettier`; the runner
needs no `--prettier` flag of its own, because it runs each `exec:` via
`bash -c` and the environment passes straight through.

## The pin

`prettier-version` holds the one version this gate is normative against,
and the pre-flight rejects any other with exit 2. Without it the verdict
belonged to whichever binary the caller happened to supply: on this repo's
57 tracked `.md` files, 3.6.2 and 3.9.6 disagree about two of them —
`docs/decisions/looper-defend.md` and
`skills/looper-commit/templates/structured-recap.md` each pass under one
version and fail under the other. 3.6.2 is additionally unusable here: it
has no fixed point on `docs/decisions/looper-custodian.md`, where each `--write`
pass adds four more spaces of indent and the first pass collapses a nested
list that both CommonMark and GitHub render.

The gate cannot install prettier — `npx` and `npm run` are denied in the
sandbox it runs in — so the pin is enforced, not applied. The repo carries
no `package.json` by design; CI installs the pinned version from this file
and hands it over via `$PRETTIER`.

## Measurement

`replay.sh` scores the gate against the loop's own `history-index.jsonl`:
the format-scope class re-violated on `linklater/feature-dyslexic-font-
accessibility` (an out-of-glob `.css` a full-tree `npm run format` silently
no-oped), caught late by crew. Under this gate that recurrence stays RED
until the touched file is actually clean, so it cannot re-ship.
