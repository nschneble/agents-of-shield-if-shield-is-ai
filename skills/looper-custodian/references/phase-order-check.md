# Phase-order check

Why the phase-order check's P2 discriminator is decidable, what each class it
prints means, and what a clean result does not buy. The governing rules live
elsewhere — SKILL.md `## Maintenance run` states the one-at-a-time rule the
check compiles, and `docs/looper-custodian.md` decision 24 records the incidents
that produced it. `scripts/custodian-phase-order.sh` is the implementation.
Consult this file when reading, changing, or arguing about the check.

## What it reads

A run's `custodian-log.jsonl`, split into segments at each `phase:"resume"`
line, the marker opening the new segment. Only phase B and E lines are ordered
against each other — C, A and F are not, and `D-apply` is a separate
human-triggered invocation rather than part of the run. A resume replays its own
tail, and the rule binds that tail on its own terms, which is why the segment
split exists at all.

## Predicate spec

Two predicates, both exiting 1:

- **P1** — no phase-E line ahead of a phase-B line inside one segment. One
  violation per phase-E line that some later phase-B line in its own segment
  follows.
- **P2** — no segment carrying phase-E lines and no phase-B line logged anywhere
  at or before it. P2 exists because P1 alone cannot see the MODAL failure: "E
  logged, B never logged" is what a run looks like when the order broke and the
  run then died, so exempting that shape would leave the check structurally
  unable to report its own most likely subject.

Three classes are REPORTED and never counted:

- **`RESUME TAIL`** — a segment with phase-E lines, no phase-B line of its own,
  but at least one phase-B line logged earlier. The documented resume shape.
- **`NOT EVALUABLE`** — a segment with phase-B lines and no phase-E line. There
  is genuinely nothing to order. Only B and E lines are grouped into segments,
  so a segment holding neither produces no row at all rather than this one.
- **`MALFORMED`** — a line whose parsed value is not an object carrying a
  `phase` key, whether it failed to parse at all or parsed without the key.
  There is deliberately NO date-based exemption: `phase` predates every log on
  disk, and the asserted C → A → B → E order predates decision 24 — decision 13
  is where that order is set — so an archived log is old, not pre-schema. A
  check that floods false positives on history gets ignored.

A log yielding ZERO parseable phase records is neither clean nor violated —
nothing was asserted at all. That is an unusable input (schema drift, or the
wrong file), so it prints **`NOTHING CHECKED`** rather than a fabricated clean
total.

Exit contract: **0 clean · 1 any violation (P1 or P2) · 2 usage/env error, an
unreadable or empty log, or `NOTHING CHECKED`.**

## Why "at or before it" is decidable, not guessed

P2 first read every no-B segment as a violation. The discriminator that fixed it
asks whether a phase-B line exists EARLIER in the log, and that question is
decidable from the log rather than inferred:

A no-B segment holds zero phase-B lines by construction, so every phase-B line
in the log lies either before its first line or after its last. "A phase-B line
with a lower line number" therefore names exactly the phase-B lines in a PRIOR
segment. The log's FIRST segment has no prior segment — whatever number the
report gives it, which is 2 when the log opens on a resume marker — so the
modal shape can never match it and stays flagged.

When a prior phase-B line DOES exist, the segment is the documented resume shape
rather than a violation. SKILL.md `## Two modes` defines a resume as replaying
"only the unlogged tail (Phase E → report issue), reusing the C/A/B already in
`custodian-log.jsonl`", and the rule binds a tail only conditionally — SKILL.md
`## Resume`: "If the unlogged tail contains both B and E, B runs to completion
before the resume's pre-E probe is taken". An E-only tail breaks no obligation,
so it is reported as `RESUME TAIL` and never counted. Without the discriminator
P2 flagged every conforming resume against the rule it cites — the defect
decision 24 records.

## Three limits, stated rather than papered over

1. **Log order only.** A clean result is evidence the log is well ordered, NOT
   evidence the runtime was serialized — a run that dispatched out of order and
   logged in order passes. Nothing here measures dispatch, concurrency, or
   per-phase cost, and no such observable exists. This is the same cap P1
   carries, and the check's own printed report states it on every run that
   prints a report.
2. **A prior phase-B line proves B was logged once in this run, NOT that the
   tail had no fresh phase-B obligation.** A resume that needed B again and
   never logged it goes quiet here. That is a live shape rather than a
   hypothetical: 2026-08-03's own resume tail logged
   `B "staleness resolved against live tree (resume)"` after two phase-E lines,
   and a death between them would print `RESUME TAIL` and exit 0 on a genuine
   E-before-B-then-dead tail. Bounded, because such a run is not the "B never
   logged at all" shape P2 exists for. Accepted because the only discriminator
   left is reading the action text, which this design refuses everywhere else —
   named, not closed.
3. **It cannot show the prior phase B RETURNED before the tail's phase E was
   probed**, only that its line precedes.
