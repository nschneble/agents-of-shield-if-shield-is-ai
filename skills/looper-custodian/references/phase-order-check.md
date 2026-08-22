# Phase-order check

Why the phase-order check's P2 discriminator is decidable, what each class
it prints means, what a clean result does not buy, why Phase E's
concurrency is removed rather than estimated, and what that removal costs.
The governing rules live elsewhere — SKILL.md `## Maintenance run` states
the one-at-a-time rule the check compiles, and `docs/decisions/looper-custodian.md`
decision 24 records the incidents that produced it.
`scripts/custodian-phase-order.sh` is the implementation. Consult this file
when reading, changing, or arguing about the check.

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
`custodian-log.jsonl`", and the rule binds a tail only conditionally — the resume rule stated under
SKILL.md `## Resume`: "If the unlogged tail contains both B and E, B runs to
completion before the resume's pre-E probe is taken". An E-only tail breaks no obligation,
so it is reported as `RESUME TAIL` and never counted. Without the discriminator
P2 flagged every conforming resume against the rule it cites — the defect
decision 24 records.

## What a clean result buys

A broken Monday is visible the same week instead of whenever someone next
reads a log by hand. What it does NOT buy is `## Three limits, stated rather
than papered over`, below.
**Know where it cannot reach: it runs at Phase F, so a run killed before F
produces no verdict at all until a resume carries it to F.** That is the
shape of both runs it was written for — 2026-08-03 hit the session limit at
09:49 and 2026-07-27 logged a kill at 09:29, each before Phase F. Both
reached F eventually, but only on the far side of a resume, and a run nobody
resumes is never checked. The cron wrapper's INCOMPLETE path already renders
`phases_summary()` over the partial log and is the obvious place a
partial-log check could run; considered and deferred, not overlooked.
`scripts/custodian-phase-order.test.sh` is its both-directions test.

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

## Why the concurrency is removed rather than estimated

Documenting the interleave rather than removing the concurrency — letting
E's sizing subtract the cost of work still in flight — is not a real option.
Be exact about what is missing, because a per-phase instrument does exist:
the re-probe after `deep-research` returns logs `utilization` before →
after, and bracketing a phase that way yields an OBSERVED cost for it. What
has no observable is the **not-yet-spent concurrent cost at probe time**.
The fan-out width is fixed in the research brief before `deep-research` is
invoked, and its internal execution cannot be batched, throttled, or
interrupted mid-flight, so no later measurement can still change the ask —
the sizing decision has to be made before the cost it would subtract exists.
Subtracting it means inventing it, which is precisely the fake gauge
`loop-de-looper`'s `## Budget governor` bans, and the mirror image of what
the `read_ok:false` rule refuses: an unread window is unread, never 0%. So
the concurrency is removed rather than estimated.

## What the removal costs

**What the rule costs is wall clock, and that cost is real.** Phase E's `deep-research` runs as a harness-backgrounded workflow that the CLI blocks for at end-of-turn, capped by `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` (`references/scheduling.md`). Dispatching E early overlaps its runtime with Phase B's work, so less of it is left to wait out when the turn ends — very likely what the 2026-08-03 run was buying. Serializing gives that overlap up and pushes E later in the session, with more of its runtime falling inside the end-of-turn wait. Accepted, on one ground: a reading is only worth taking if nothing invalidates it between the reading and its use, and a ceiling-kill is a detected, resumable state (`references/resume.md`), where a reading that was already wrong when it was used leaves nothing to detect.
