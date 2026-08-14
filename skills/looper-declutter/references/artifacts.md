# Artifacts + findings log

On-disk record shapes for a declutter run. Loaded by `SKILL.md` `## The phases`. Same role `loop-de-looper/references/state-schemas.md` plays for a loop run.

`<run-id>` is a UTC start stamp (e.g. `2026-07-30T14-30Z`), distinct at a glance from a `#<snip-id>` (e.g. `#D-3`).

Under `local/declutter/<run-id>/` (gitignored, same status as `local/defend/` and `local/loops/`):

- **`findings.jsonl`** — append-only, one record per candidate. The machine record; the report's claims trace to it.
- **`report.md`** — the human-review + `apply` surface, with `D-<n>` checkboxes read back by `apply` (checkboxes only, no free-text approval parsing).

`findings.jsonl` record — one line per candidate:

```json
{
  "snip_id": "D-3",
  "phase": "triage",
  "location": "src/widget.ts:42",
  "kinds": ["stacked-slashes", "over-75"],
  "current": "// first line\n// second line",
  "proposal": "// one tight why line",
  "owner_rule": "the-chronicler:comment-style",
  "outcome": "snip",
  "ran": null,
  "task_tool_available": null
}
```

- **`kinds`** lists every kind the one comment tripped, which is what makes dedupe-by-comment auditable — one record per comment, not one per kind.
- **`outcome`** is `snip` (actionable) or `keep` (informational, no checkbox); `null` on a bare scan record.
- **`ran`/`task_tool_available`** are snip-record fields only — `task_tool_available: false ⇒ ran: false`, a snip declutter could not run is logged unavailable, never claimed. Same rule as `gates.jsonl` and defend's `findings.jsonl`.
