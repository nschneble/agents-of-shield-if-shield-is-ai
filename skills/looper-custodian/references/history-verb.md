# `history` — cross-run index query

The verb's query grammar, its filter flags, and what its cited output returns.
SKILL.md's `history` section is the pointer site, and
`scripts/custodian-history.sh` is the implementation. Consult this file when
running, scripting, or changing a `history` query.

Backed by `scripts/custodian-history.sh query`:

```
scripts/custodian-history.sh query <q> \
  [--agent S] [--verdict S] [--kind S] [--repo S] [--file S] [--blocked] [--limit N]
```

Read-only lookup over `history-index.jsonl`. Returns **ranked, cited matches** — most-recent-first (by the source `gates.jsonl` mtime), each printed with its `cite` (`<repo>/local/loops/<branch>/gates.jsonl:<n>`) so every hit traces to source, same way `ctx` returns cited snippets rather than raw logs. `<q>` is a case-insensitive substring over summary+agent+verdict+kind; all flags are case-insensitive substrings too (real `verdict`s are free-text prose like `"CHANGES REQUESTED"`, not an enum — so match on substrings, and use `--blocked` for the reliable `blockers>0` "flagged" signal). Filters compose:

- `--file src/auth.ts` → "what happened last time we touched this" (ctx's file filter, re-created from the indexed `files`).
- `--agent the-diamantaire --blocked` → "everything this crew agent flagged with blockers."
- `--kind wave-retry --repo linklater` → "which waves needed retries here."

`scripts/custodian-history.sh rebuild` wipes and re-derives the whole index from every `gates.jsonl` — safe anytime, since the index is a derived cache. Query writes nothing; disposes nothing; never part of the scheduled run. Human- or agent-triggered, like `apply`/`undo`.
