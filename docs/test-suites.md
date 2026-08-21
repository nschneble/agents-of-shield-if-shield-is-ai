# Test suites — why each one is shaped the way it is

Every `*.test.sh` in this repo carries a short header naming the problem it
solves, its method, and a pointer here. The depth lives in this file: fixture
provenance, the incident that motivated an arm, the invariant lists, and the
reasoning behind a non-obvious harness choice.

Section names match suite names: `scripts/<name>.test.sh`, except
`guard-destructive-git` and `guard-pr-template`, which live in `hooks/`.

## House doctrine

Stated once here because most of the headers used to state it each.

**Both directions.** Standing rule: a new invariant is tested RED (goes off on
a violating fixture) AND green (clean fixture passes).

**Self-contained fixtures.** Fixtures are written by the suite — never read
from gitignored `local/`. Pure bash + jq, self-contained.

## custodian-guardrails

Both-directions test for the guardrail replay.

Proves each of G1/G2/G3 flags its own violation with the record's verbatim
cite, that exit is 1 on any violation and 0 when clean, and that the legacy
exemption keeps a pre-schema line that WOULD trip G2 out of the violation set.

Also covers two properties the legacy exemption depends on:

- REBUILD-SIMULATION: a legacy source line pushed through the REAL ingest
  writer (`custodian-history.sh rebuild`) must still classify legacy/exempt, and
  a modern verified_by:null line must classify modern — so the exemption survives
  `history --rebuild` (the writer preserves source key-absence, not a `// null`).
- G2 ⇔ state-schemas SYNC: G2 must select the SAME lines as the canonical
  provenance lint in state-schemas.md, so the "reused, not forked" claim holds.

Pure bash + jq, self-contained fixtures.

## custodian-log-recall

Both-directions test for the recall check.

Both directions matter more in this suite than in most, because the failure
this check exists to catch is an ABSENCE. A check that reports a missing line
is easy; a check that stays quiet when the line is present, and that refuses
to call an unfired rule clean, is the part that can silently rot into "always
green" or "always red".

So four verdict classes are pinned, not two: SATISFIED, VIOLATION, NOT
EVALUABLE, and the UNDECLARED exit that fires when the spec grows a
requirement nobody taught the check to time.

Self-contained: fixture spec + fixture logs in a temp dir. No git, no network,
and it never reads the real local/custodian corpus.

## custodian-phase-order

Both-directions test for the phase-order log check.

Proves both predicates go off citing their offending lines verbatim, that the
exit code tracks them, and that every report-only class stays out of the
violation set. The predicates, those classes and the exit contract are spec'd
in skills/looper-custodian/references/phase-order-check.md.

Six further properties the check's honesty depends on:

- SEGMENTATION is load-bearing: deleting the `resume` marker from
  the GREEN fixture, and changing nothing else, must turn it RED.
  Without that arm a check that ignored segments entirely would
  still pass GREEN, and decision 24's resume clause would be
  untested.
- The EXIT CODE must agree with the report's own printed total on
  every fixture. It once did not: the code was scraped back out of
  the rendered prose, so a newline inside a logged `action` injected
  a counterfeit `TOTAL VIOLATIONS: 0` that `head -1` preferred, and
  a real violation exited 0. `agree` in the suite re-derives the expected
  code from the LAST total line on every case, and one fixture
  carries that injection deliberately.
- NOTHING CHECKED is not clean: a log the check cannot read asserts
  nothing, so it must be distinguishable from a verified run at BOTH
  the headline and the exit code, or schema drift greens the gate
  forever.
- The P2 DISCRIMINATOR reads the earlier phase-B line, not the
  segment number. One fixture pair carries both directions: a
  textbook E-only resume tail exits 0, and the same fixture with its
  phase-B lines deleted exits 1. Without the pair, a check that
  flagged every no-B segment and a check that flagged none would
  each pass some single arm.
- CLAIM DISCIPLINE, in both directions, INCLUDING on the
  disclaimer's own line. The report must say it asserts log order
  only (decision 24 caps what this check may claim), and it must NOT
  say anything more. The negative arm strips the pinned SUBSTRING
  rather than the line it sits on: dropping the line hid every
  overclaim welded onto it, which is the one place a future edit is
  actually likely to put one.
- SINGLE HOME, the one property in this suite that is about the repo rather
  than the report. The discriminator argument is stated once, in
  the reference, and no linter compares two prose copies of a rule
  — so the restructure that gave it one home rests on review alone
  unless something counts. This suite counts.

Deliberately over the ~100-line refactor bar, and the reason covers part of
the suite rather than all of it. Two fixtures are welded to their assertions:
RED and DIED carry all four of the cited-LINE-NUMBER arms (`precedes line 6`,
`MALFORMED  line 9`, `MALFORMED  line 10`, `first at line 3`), so moving them
to a second file would strand them where they cannot see the fixture that
numbers them, and every future fixture edit would drift them silently. That
claims 75 code lines — RED 56, DIED 19 — and no more. The other fixtures
assert on content with `grep -q`, carry no line-number coupling, and would
split cleanly — they stay in this suite for convenience, not cohesion. The
bulk is arithmetic, not slack — an arm costs two lines (the probe, then
`check`), so the assertion floor at the foot of the suite already prices most
of the body. Trim its prose before reaching for its code.

## custodian-skill-lint

Both-directions test for the skill linter.

Standing rule: a new invariant is tested RED (fires on a violating fixture)
AND green (clean fixture passes). This proves each STRUCTURAL check flags its
own violation with the offending file cited, that exit is 1 on any structural
violation and 0 when clean, and — crucially for the two-tier design — that an
ADVISORY-only fixture (over the token budgets, nothing structurally wrong)
still exits 0. Pure bash + jq-free, self-contained fixtures under a temp dir.

## loop-finding-audit

Both-directions test for the finding admissibility audit.

An audit that silently stopped checking an arm prints "0 violations" — the
same words as a clean run — so the arm COUNT in the headline is asserted too.

Four properties the audit's honesty depends on:

- A LEGACY LOG IS A VIOLATING LOG, not an exempt one. Runs that
  predate the justification fields spent correctives they cannot
  account for, and that is the finding, not a schema gap to wave
  through. Both real logs this check was written against exit 1 for
  exactly this reason, and a fixture in this suite pins the same shape.
- SPENDING IS COUNTED FROM BOTH RECORDS, JUSTIFICATION FROM THE LOG
  ALONE. Each spending source is blind where the other sees: only
  the snapshot's counter records a corrective numbered as an
  ordinary queue wave, and only the log's labels survive an
  under-reported counter. Taking either alone leaves a one-field
  way around the whole check, and both have a RED fixture.
- AN UNRESOLVABLE ASK ID IS WORSE THAN A MISSING ONE. `contract_ref:
"A7"` on a run whose contract has two asks reads as justified from
  every angle except the one that resolves it.
- EXIT 0 MEANS FULLY CHECKED. A missing snapshot skips two arms, so
  the run exits 2 even with every surviving arm green — a caller
  gating on `$?` must never read a half-run audit as a clean one.

## loop-receipts

Both-directions test for the receipt check, and for the hook that writes what
it reads.

The hook half matters as much as the check half: a hook that silently writes
nothing makes every branch NOT EVALUABLE, which is a clean exit forever. So
the writer is exercised against real payload shapes, not assumed.

THE FIXTURES IN THIS SUITE ARE THE PAYLOAD THE RUNTIME ACTUALLY SENDS, dumped
from a live PostToolUse call: tool_response carries interrupted, isImage,
noOutputExpected, stderr, stdout — and no exit code, under any spelling. An
earlier version of this suite hand-wrote `exit_code: 0`, asserted on it, and
passed green while the check it covers could not reach its own clean arm on a
single real branch. A fixture that manufactures the schema it validates proves
nothing.

## loop-state-audit

Both-directions test for the run-state drift audit.

Every comparison arm gets both directions, because an audit that silently
stopped comparing would print `STATE DRIFT: 0` — the same words as a clean
run. The arm count in the headline is what separates those two, so it is
asserted too.

Five properties the audit's honesty depends on:

- THE LIVE SEGMENT is load-bearing. A `commit` line above a later
  `_declared` belongs to a superseded dispatch, so the wave is NOT
  shipped. One fixture pair carries both directions: the same lines
  with and without the trailing declaration. Without the pair, an
  audit that grepped the whole file for `commit` and an audit that
  read segments correctly would each pass some single arm.
- NOT EVALUABLE is not clean. A journal with an unparseable line
  cannot be typed, so the four journal-derived arms are SKIPPED
  rather than compared against a floor — and the report has to say
  which wave and why, or a damaged journal quietly shrinks the
  comparison to the arms that happen to still work.
- The EXIT CODE tracks the printed drift count on every fixture, so
  a caller branching on `$?` and a human reading the report never
  disagree. `agree` in the suite re-derives it from the report's own
  headline rather than restating an expected number.
- EXIT 0 MEANS FULLY CHECKED, not "nothing I compared disagreed".
  A resume branches on this code to decide whether to trust the
  snapshot, so a run whose position arms were skipped exits 2 even
  with every surviving arm green — and a disagreement the audit did
  settle outranks that, since drift is actionable and a gap is only
  a reason to go looking. Both directions have an arm.
- A LEGACY SNAPSHOT IS NOT A DRIFTING ONE. Older run dirs key queue
  entries `n` with a prose status, carry no `last_crew_wave`, and
  hold no journals; each oracle must decline rather than report the
  schema gap as lost position. Caught by sweeping real dirs in
  sibling repos, where the first cut reddened every arm of all four.

## looper-custodian-cron

End-to-end test for the run-start usage-window gate in
scripts/looper-custodian-cron.sh, and for the launch that gate guards.

Drives every arm of the wrapper's `case "$gate_state"` through a stub probe,
with claude, gh, osascript and sleep stubbed on PATH — a run of this suite
costs no session, opens no issue and waits no seconds. Reachable at all only
because the wrapper takes REPO / LOGDIR / WINDOW_PROBE /
CUSTODIAN_PATH_PREFIX; the last of those is what makes the stubs bite, since
the wrapper PREPENDS /opt/homebrew/bin:/usr/bin:/bin:/usr/sbin: /sbin and so
shadows a stub dir handed in through PATH.

PROBE FIXTURE PROVENANCE — both shapes were CAPTURED by running the real
scripts/usage-window-probe.sh on 2026-08-20, never hand-written:

```
read_ok:true    one live probe; the account read `allowed` on both
                windows, at 58% (5h) and 42% (weekly)
read_ok:false   the same probe under HOME=<empty dir> and a
                nonexistent USER, reaching its emit_unreadable arm
```

They differ in whitespace — json.dumps spacing against a bare printf — and
that asymmetry is the half a hand-written payload gets wrong. Hot and rejected
fixtures vary ONLY utilization, status and reset on the captured line, through
jq. `status: "rejected"` is the one value not observed live: the account was
`allowed`, and the probe passes the anthropic-ratelimit-unified-*-status
header through verbatim.

Both directions on every axis the gate branches on, and every arm of its case:
a clear window LAUNCHES and a hot one DEFERS; a hot weekly defers with NO wait
while a hot 5-hour one waits first; a `rejected` status is narrated as a hard
stop, never as a threshold trip; and every way the window goes UNREAD is named
as the reason it was — with the offending value, where an operator supplied
one — never as a reading.

Past the gate, a launch is checked for WHAT it launches, not just that it
happened: every launching case matches the whole argv, so neither the
`/looper-custodian` payload nor `--dangerously-skip-permissions` can go
missing while the suite stays green. The REPO seam is checked the same way in
both directions — it decides the cwd claude runs in, and an unenterable one
must refuse the run, not launch somewhere else.

## skill-body-ceiling

Both-directions test for the body-ceiling check.

The failure that matters is a check that stops checking: a ceilings file it
cannot read, a row it skips, a comparison that never fires. Each of those
looks exactly like a clean run from the outside, so the shapes are pinned in
this suite rather than the happy path alone.

## temp-dir-guard

Both-directions test for the temp-dir guard that every self-contained suite
carries.

The defect this suite locks down, observed live: an unchecked
`temp_dir=$(mktemp -d)` returns empty when the temp dir is denied or full.
Every path derived from it then resolves absolute (/repo), the mkdir and cd
that follow fail while silenced, and the suite's git fixture commands execute
with the CWD still on the INVOKING repo, committing its working tree via `git
add -A` and overwriting its user.email.

RED: mktemp is broken all THREE ways it breaks in the wild — a non-zero exit;
a success that yields an empty string, which is the failure the guard's `-n`
arm exists for and the one an exit-status-only guard survives; and a success
handing back a real path that is a regular FILE, which is what `mktemp -d`
degraded to a plain `mktemp` produces and what the guard's `-d` arm exists
for. Under each, a suite must exit 2, print its own refusal in words true of
THAT shape, and leave a victim repo byte-identical. GREEN: with a working
mktemp each suite still passes and still leaves the victim untouched, so the
guard costs the healthy path nothing.

One shim per fault SHAPE, never per message. The guard grew from one arm to
three while this loop still iterated two shims, so the third arm was
decoration: deleting it from every roster suite, or corrupting its wording,
left this suite printing "all temp-dir guard tests passed".

The roster is DERIVED, never hand-listed: every `*.test.sh` in the repo that
mentions mktemp, minus this file. A hardcoded list covers the suites someone
remembered; the seventh suite would be covered by nothing and fail nothing.
Derivation has its own three failure modes, all of which used to pass:
narrowing it to a subset (pinned by a second count spelled with find rather
than a recursive grep); emptying it altogether (pinned by running a copy of
this suite alone in a bare tree, because an empty array under `set -u` is
legal on the bash CI runs); and WIDENING it back over `local/` (pinned by a
planted scratch suite that must be neither counted nor executed).

scripts/custodian-history.sh is checked by name at the end of the suite. It
carries the same guard but is not a suite, so no derivation over `*.test.sh`
can ever reach it.

Deliberately over the ~100-line refactor bar. Splitting it would put the
derivation, the shims and the drift oracle in separate files, and a roster
that cannot see its own shims is the exact failure this suite was written to
catch. Trim its prose before reaching for its code.

## validate-looper-config

Both-directions test for the config validator: its CI-wiring check, its
frontmatter checks, and its reference-integrity warnings.

The wiring check is why this suite exists. It has been wrong in BOTH
directions and reddened nothing either time. Matching only lines that start
`run:` missed a suite invoked inside a `run: |` block scalar and called a
wired suite unwired. Widening the match to the whole YAML body then accepted
any MENTION: with the real step deleted, a suite named in a step `name:`, in
an `on: push: paths:` filter, or in a trailing `# TODO` comment all read as
wired. So both directions are pinned in this suite — the spellings CI never
executes must ERROR, and the three it does execute must not.

Self-contained: builds a fixture repo in a temp dir carrying its own copy of
the validator, which resolves its repo root from its own path. No git, no
network. Needs a writable temp dir, so it must run sandbox-off locally; it
aborts rather than degrade when it cannot get one.

The verdict is derived from a results LOG, and an expected assertion count is
asserted alongside it. Both because this suite is now what guarantees every
other suite reaches CI, and a guarantor that can false-green through its own
accountant guarantees nothing.

## guard-destructive-git

Both-directions test for the PreToolUse guard.

Standing rule: RED (the guard denies what it claims to deny) AND green
(ordinary work is not blocked). The green half is the load-bearing one in this
suite: a guard that over-blocks gets disabled, and a disabled guard protects
nothing.

The guard reads a PreToolUse payload on stdin and, to DENY, prints a JSON
object carrying permissionDecision:"deny". To ALLOW it prints nothing. Exit
status is 0 either way, so the decision is read from stdout, never from `$?`.

Self-contained: no git repo, no network, no temp files — the guard is a pure
stdin/stdout filter.

## guard-pr-template

Both-directions test for the PR-template guard.

Both directions matter for opposite reasons. A guard that never fires is the
status quo it was built to replace. A guard that fires on a body that DID
follow the template teaches people to route around it, and a routed-around
guard is worse than none because it also reads as enforcement. So the
fail-open arms are tested as carefully as the bite.

Self-contained: builds fixture repos in a temp dir, feeds the hook the same
PreToolUse JSON Claude Code sends. No git remote, no network, no ~/.claude.
Needs a writable temp dir and aborts rather than degrade.
