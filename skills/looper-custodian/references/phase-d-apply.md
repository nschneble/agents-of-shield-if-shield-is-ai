# Phase D — apply, `--dry-run`, `undo`

The human-triggered write path: what `apply` does step by step, what
`--dry-run` prints instead, and what `undo` restores. SKILL.md
`## Phase D — apply (gated, the only place custodian writes)` is the pointer
site, and the propose-vs-dispose line this path sits on is stated there under
`## Governing principle: custodian PROPOSES, human DISPOSES`. Consult this file
when running or changing an apply.

Triggered ONLY by `/looper-custodian apply #<issue>`. Never on the cron.

1. Read the issue body via `gh`. Parse the checkboxes: a ticked `[x]` tag applies; an unticked `[ ]` is skipped. **No free-text approval parsing** — boxes only.
2. **Snapshot before any write.** Copy every file a ticked item will touch into `local/custodian/<date>/backup-<issue>-<seq>/`, alongside a `manifest.json` listing each backed-up path + its original location + the issue tag that touched it. The snapshot is taken whole, BEFORE the first edit, so `undo` restores a consistent pre-apply state even if apply halts mid-run. (`--dry-run` skips this — it writes nothing to snapshot.)
3. For each ticked `B-merge`/`B-retire`/`B-distill`/`B-repoint`/`B-migrate`: apply the memory merge/retire/distill/re-point/migrate (the only place custodian writes a memory). Leave the `[[link]]` breadcrumb on retire, and on distill link the retired episodic instances into the new semantic memory as its evidence. A `B-repoint` is the one NON-destructive memory write that touches a single file: edit the stale citation in place to its new location, keeping the memory otherwise intact — no removal, no breadcrumb. A `B-migrate` is non-destructive across TWO namespaces: copy the entry (unchanged) into the correct namespace's memory dir, add its `MEMORY.md` index line there, and leave a one-line `[[breadcrumb]]` in the original pointing at the new location — the original file stays in place, never deleted, so a wrong migration call is a cheap `undo` away.
4. For each ticked `D-turncoat`: invoke `the-turncoat` via the Task tool with the specific flagged target. Custodian decides _what_ to hand it; turncoat decides _how_ to trim; the human approved _that it runs_. Custodian never hand-edits an agent itself.
5. For each ticked `E-<n>` that maps to a build: hand it off as a scoped change (note it for the user / a `loop-de-looper` run) — custodian does not itself implement features.
6. **Idempotent.** Diff current state first; an already-applied item is a no-op, never a double-edit. Re-running `apply` on the same issue is safe.
7. **Audit every write.** Log each applied edit (file, before/after summary, backup path) to `custodian-log.jsonl`, and comment the summary back on the issue — including the backup dir and the `undo` command so the reversal is one copy-paste away.
8. Applied edits to tracked files (memory dir, agents) go through the **normal review/commit path** — never silently committed by custodian.

### `--dry-run` — preview, write nothing

`apply #<issue> --dry-run` runs steps 1 + 3–5 in _describe_ mode: for each ticked item it prints the exact before/after (the verbatim memory lines being merged/retired/distilled, the turncoat target + its current vs proposed shape, the scoped-change hand-off text) and STOPS. No snapshot (step 2), no write, no log, no issue comment. The point: the human approves the literal diff, not a paraphrase of it. A real `apply` after a `--dry-run` is the same command without the flag.

### `undo` — restore the last snapshot

`undo` reads the most recent `backup-*/manifest.json` under `local/custodian/`, and restores each listed file to its backed-up content, reverting the last `apply`. Idempotent: if the current files already match the backup (nothing to revert, or `undo` already ran), it's a no-op and says so. `undo` reverts custodian's _working-tree_ writes; tracked-file edits already committed are reverted through the normal git path (custodian never force-rewrites history — the destructive-git guard blocks that anyway). One level deep: `undo` restores the latest snapshot, not a stack.
