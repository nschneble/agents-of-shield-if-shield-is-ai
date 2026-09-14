# Unanimous crew verdicts with zero execution backing

Verdict on issue #89's question of whether this system's review gates ever
produce a PASS with nothing executed behind it, scoped to the gap the two
existing tools leave open.

**CONFIRMED.** Five wave groups reached a unanimous all-clean crew verdict in
which not one reviewer claimed execution behind it. All five are modern-era
records, so the field was there to fill and was filled with `llm` or `null`.

## What was already covered, and why it did not answer this

Both existing tools were run first over everything they cover.

`scripts/custodian-guardrails.sh` over the 1397-record cross-repo index — exit
1, 16 violations: G1 0 of 777 checked, G2 1 of 566 checked, G3 15 of 141 waves
checked.

`scripts/loop-receipts.sh --dir` over all 12 live gate directories — every one
exit 0. Ten evaluable, two NOT EVALUABLE for want of a receipts log
(`linklater/main-v160-review`, `rss-reader/theme-palette-logo`), zero
violations. It still has no batch mode; the loop over directories is the
caller's job.

Neither reaches the question:

- **G2 is line-level and content-blind.** It asks whether a line carries _a_
  `verified_by` value, never whether the value means execution. Every one of
  the five findings passes G2, because `"llm"` is a value.
- **G3 is the near neighbour, and it already flags three of the five.** It is
  wave-level and does test `all(.[]; .verified_by != "executable")`. Of the
  five findings it flags `issue-74-real-entry-point-verify` w1,
  `feature-dyslexic-font-accessibility` w4 and
  `fix/collapse-run-scheduled-story-params` w1 — but as committed waves lacking
  execution evidence, which is a different claim about the same lines. It says
  nothing about who agreed with whom. The two it cannot see at all are
  `issue-72-verify-brief-claims` w1 and `fix/58-1-dedup-readjsonbaseline` w1,
  which its committed-wave predicate never selects. So the strictly new
  detections are two; the other three are a second, sharper reading of waves
  already known to be unbacked.
- **`loop-receipts` only audits a claim that was made.** A wave claiming
  nothing has nothing for it to check.

## The gap, stated as a predicate

Group crew gate lines by `repo|branch|wave|pass`. A group is a finding when all
of:

1. at least two DISTINCT reviewer agents, none of them a rollup line;
2. every line `ran: true` — a line that did not run carries no verdict;
3. every line `blockers: 0` — unanimously clean;
4. every line's `verified_by` is `"llm"` or null;
5. every line carries the `verified_by` key, so the record is modern-era and
   the silence is a choice rather than a schema gap.

`scripts/loop-unanimity-audit.sh` is that predicate. Corpus is the custodian
history index plus every live `local/loops/*/gates.jsonl`, deduped on `cite`.

## The replay

```
corpus:   index 1397 line(s) · census 314 line(s) from 12 file(s)
          1556 deduped · 990 crew · 850 usable (dropped 91 not-ran, 49 wave-null)

groups (repo|branch|wave|pass)
  total                      200
  single-reviewer            40   (not a unanimity; excluded)
  rollup-agent               10   (all-six/crew/slash lines; excluded)
  multi-reviewer             150
  UNANIMOUS all-clean        96
  unanimous all-flagging     4    (agree a defect exists; SAME defect NOT checkable)
  carrying a real pass field 27   (index records carry none)

execution backing behind the unanimous all-clean groups
  T1 zero (every verified_by llm/null/absent)  38
    of those, all-legacy-era (field predates)  33   unevidenced, NOT a finding
    of those, modern-era                       5    <- the finding
  T2 zero (no verified_by == "executable")     40

VERDICT: 5 of 96 unanimous all-clean group(s) had zero execution backing (5%)
```

The five, with the count of reviewers that actually ran against the crew lines
logged for that wave:

| Group                                                                  | ran / logged | receipts      |
| ---------------------------------------------------------------------- | ------------ | ------------- |
| `agents-of-shield-if-shield-is-ai/issue-72-verify-brief-claims` w1     | 4 / 4        | NOT EVALUABLE |
| `agents-of-shield-if-shield-is-ai/issue-74-real-entry-point-verify` w1 | 3 / 7        | NOT EVALUABLE |
| `linklater/feature-dyslexic-font-accessibility` w4                     | 7 / 7        | NOT EVALUABLE |
| `tuffgal/fix/58-1-dedup-readjsonbaseline` w1                           | 6 / 7        | NOT EVALUABLE |
| `tuffgal/fix/collapse-run-scheduled-story-params` w1                   | 4 / 7        | NOT EVALUABLE |

Two of them are unanimities of a minority. On
`issue-74-real-entry-point-verify` wave 1, seven crew lines were logged and
three carry `ran: true`; the other four have `ran: null` and no verdict. The
wave's crew pass reads as unanimous because the reviewers who did not run also
did not dissent. `tuffgal/fix/collapse-run-scheduled-story-params` wave 1 is
the same shape at four of seven.

Every receipts column is NOT EVALUABLE for the same reason: all five branches
have been reaped from disk, so there is no `receipts.jsonl` to corroborate
against. Per `loop-receipts`' own era-gate doctrine that is unevidenced, not
disproved — it neither strengthens nor weakens the finding, which rests on the
gate log alone.

## What the audit deliberately does not claim

- **"All flagging the same thing" is not mechanized.** `verdict` and `summary`
  are verbatim prose. The audit reports all-clean unanimity, which `blockers`
  settles, and counts all-flagging groups (4) separately without asserting the
  flags match. Nothing in the schema would let it.
- **The index carries no `pass` field on any of its 1397 records**, so its
  groups are wave-coarse and merge interim with final. That makes unanimity
  HARDER to reach, not easier, so the count under-reports. Only the 27 groups
  from live files have a real pass.
- **33 legacy-era groups are excluded, not cleared.** Their records predate
  `verified_by`. They are unevidenced either way, and folding them in would
  report 38 rather than 5 — turning a schema gap into the bulk of the finding.
- **`verified_by` is free text** — 61 distinct values across the index, mostly
  one-off prose like `orchestrator, ran the suite`. T1 is the strict reading
  (only `llm`/null counts as unbacked) and is the one the verdict uses. T2,
  which counts any non-`executable` value as unbacked, finds 40. The two groups
  in the gap are `agents-of-shield-if-shield-is-ai/outstanding-refactors` wave
  `final` and `.../reduce-reuse-recycle` wave `W0`, whose lines carry prose
  asserting execution (`orchestrator ran readlink on the live symlink`,
  `orchestrator git log -S'no_probe' main..HEAD`). Both branches are reaped, so
  no receipt corroborates either; `reduce-reuse-recycle` is also where G2's one
  violation sits.
- **The field is self-reported.** T1 trusts a reviewer saying `llm`, which is
  a reviewer accurately confessing. A reviewer typing `executable` without
  running anything is outside what this audit, or G3, can see; only receipts
  reach that, and only on branches that still have them.

## The carn gap

The history index covers five repos — `linklater` 835 records, `tuffgal` 208,
`agents-of-shield-if-shield-is-ai` 202, `tuffgal-action` 125, `rss-reader` 27.
It has zero `carn` records, while `carn` has seven live gate files carrying 153
lines, five of them with real `pass` values. The live census arm is what brings
carn into this audit at all; the index does not see it, and neither does
`custodian-guardrails.sh`, which reads the index alone. Recorded here as a
finding about coverage, not fixed in this pass.
