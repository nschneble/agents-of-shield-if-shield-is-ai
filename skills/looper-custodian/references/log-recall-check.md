# The log-recall check

What `scripts/custodian-log-recall.sh` asks, the four verdicts it can
return, the exit contract, why its triggers are declared rather than
mined from prose, and what a clean result does NOT buy. `SKILL.md
## Integration with existing pieces` points here.

Consult this file before adding a prescribed log action to the spec, or
before reading a clean result as evidence that a rule was honoured.

## The question, and why the order check cannot ask it

`scripts/custodian-phase-order.sh` asks whether the phase lines a run DID
log came in the order the run was meant to execute. It can only
interrogate lines that exist. A line the spec requires and nobody ever
writes leaves no trace, so the log reads clean precisely because the
obligation was skipped.

This asks the complementary question: for every log action the spec
prescribes, has any run ever written it?

It found its own reason for existing. `SKILL.md ## Phase E` requires a
re-probe after `deep-research` returns, logged as `action "window cost"`,
and calls that line what turns the candidate cap "from a conservative
guess into a calibrated number". Across nine archived runs the string
appears zero times, while five of them recorded deep-research returning.
The calibrated number never had a measurement behind it.

## The four verdicts

One per prescribed string, and the vocabulary is the point — three of the
four are ways of NOT asserting a violation, and each says something
different.

- **SATISFIED** — the string was observed in at least one log. The rule
  has been honoured at least once.
- **VIOLATION** — the string was never observed, AND its trigger fired in
  at least one log. Prescribed, due, never written. Exits 1.
- **NOT EVALUABLE** — never observed, and its trigger never fired either.
  Nothing is asserted. A rule whose precondition never arose owes
  nothing, and reporting that as clean would be the same fabrication the
  spec refuses everywhere else.
- **UNDECLARED** — the spec prescribes a string with no entry in
  `trigger_for`. When it comes due is unknown, so it cannot be judged.
  Exits 2 rather than passing quietly.

## Triggers are declared, not inferred

Each prescribed string needs a `trigger_for` entry: a `jq` boolean over
one log record answering "when is this line due?".

Mining the spec for that answer would be a second spec, written in regex,
rotting against the first. So the coupling runs the other way: adding a prescribed
action string to `SKILL.md` or any reference file without declaring its
trigger makes this check exit 2. That is deliberate. It
fails loudly at the moment the requirement is written rather than
silently under-reporting forever.

**If you are editing the spec and this check now exits 2, that is why.**
Add the trigger beside the others in `scripts/custodian-log-recall.sh`.

Keep triggers narrow. A trigger that over-fires manufactures violations,
which is worse than the silence this check exists to break — the
`window cost` trigger excludes six phrasings that all mean deep-research
never ran, because a run that never reached it owes no re-probe.

## Exit contract

- **0** — every prescribed line was observed, or nothing was evaluable.
- **1** — a prescribed line whose trigger fired was never logged.
- **2** — unusable input: a missing spec, a spec prescribing nothing, no
  log at all, a corpus carrying no parseable record, or a prescribed
  string with no declared trigger.

The zero-record case is an exit, not a printed line.
`scripts/custodian-phase-order.sh` refuses the same shape with
`NOTHING CHECKED`, and callers read the status, not the prose.

## What a clean result does NOT buy

1. **It reads the LOG, not the runtime.** Inherited verbatim from the
   phase-order check's own limits. "Never observed" means the spec's
   claim is unevidenced, not that the step never ran.
2. **One log satisfies a rule for the whole corpus.** A string written
   once, five runs ago, marks its rule SATISFIED even if every run since
   fired the trigger and stayed silent. The contract is "written by some
   run", not "written by every run that owed it".
3. **It only sees strings the spec quotes in one grammatical form** —
   the word `action` followed by the string in double quotes. A
   requirement phrased any other way is invisible to the harvest, and its
   absence is not a finding here. (Writing that form in prose, as this
   paragraph nearly did, makes the harvest read it as a real
   requirement — which is why this sentence describes the shape instead
   of showing it.)
