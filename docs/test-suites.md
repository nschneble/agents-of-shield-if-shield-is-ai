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

## custodian-backup

Both-directions test for Phase D's snapshot and `undo`.

`undo` is the only reversal path for an apply, so the arms that matter most
are the refusals. A snapshot that reads a file it cannot copy must exit 1
and write no manifest. The `undo` that follows must then refuse rather than
fall back to an older snapshot, because the older one belongs to a different
apply. The same refusal holds for a newest manifest in a hand-written shape
(the archive holds four), and for a snapshot missing one of its copies.
Every refusal is checked to have restored nothing.

The ordering fixture puts an older date and a lower seq beside the newest
snapshot, each holding different content. A wrong pick then restores the
wrong bytes. Shared content would let it pass unnoticed. The idempotence
arm runs `undo` twice and requires `no-op` with nothing restored. The backup
tree is checksummed before `undo` and must match exactly afterwards.

The issue fixture replays the review's case: two applies, then one that
only creates files, then a hand edit. `undo --issue` for the create-only
apply must be a no-op that leaves the hand edit, and `undo` for the earlier
issue must refuse. A `jq` shim that fails only the manifest build proves a
refused snapshot leaves no empty backup dir to block the next `undo`. The
symlink fixture replaces the link with a file holding the same bytes, so a
content compare would wrongly call it unchanged. The directory-link fixture
re-points a link to a directory, and swaps a file for one, before `undo`:
a restore that follows the link drops its temp copy inside the directory.
A real directory in the original's place must fail and stay empty.

The non-numeric `--issue` arm is layered: without the regex check, the
manifest's `--argjson` still refuses. It was watched failing with both
layers removed. So is `undo` with no `--issue`: the issue match refuses it
too.

Fixtures are memory files in a temp dir, and `CUSTODIAN_HOME` always points
inside it. The real `local/custodian` is never read.

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
  A `ran: false` line with a verdict must come through as false and trip G1;
  `// null` once turned it into null, so G1 never fired on indexed data.
- G2 ⇔ state-schemas SYNC: G2 must select the SAME lines as the canonical
  provenance lint in state-schemas.md, so the "reused, not forked" claim holds.
- ARCHIVE: plain `rebuild` indexes live dirs only;
  `rebuild --include-archive` adds each archived line under its archived
  cite, after the live dirs. `foo.2` beside `foo` is branch `foo`; a lone
  `x.2` stays `x.2`. An unknown `rebuild` argument exits 2 and leaves the
  index alone, `ingest` and `query` refuse the flag, and `query` returns
  archived records. The replay flags a live G2 line and skips the identical
  archived one. Mutants pin the archive walk, the suffix rule and the replay
  filter.

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

## custodian-mutation-kill

Both-directions test for the mutation harness.

The harness scores other suites, so the failure that matters is a harness
that scores everything green. Three shapes are pinned against fixture
scripts, never the real checks: a suite that CAN catch its mutant (killed), a
suite that cannot (SURVIVED), and a pattern that matches nothing (DID NOT
APPLY — the false-kill shape, which must be a failure and never a pass).

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

## custodian-reap

Both-directions test for Phase A's reap.

One fixture git repo holds a branch for every verdict: ancestry-merged,
squash-merged (a merged PR without ancestry), merged with an open PR,
unmerged, deleted and unmerged, a slash branch, the default branch, a dir
nesting another branch's dir, and two merged dirs the ingest guard must
block. One has a `gates.jsonl` line missing from the index and the other a
`gates.jsonl` that will not parse. The same roster runs in plan mode, which
must leave the tree byte-identical, and in `--apply` mode, which must delete
exactly the reap set and prune an emptied slash parent.

Every ancestry-merged dir names its own commit in a `run-state.json`, because
the review's case hid behind a helper that always committed. `fresh` is
created from main with no commit, `stray` records a commit off main, and
`garbled` has a `run-state.json` that will not parse; all three have merged
tips and must keep. `reused` has a merged PR for another tip, `gonepr` a
merged PR and no local branch, and `tail` an unterminated last `gates.jsonl`
line missing from the index. A dot-dir must print `skip`. `ahead` has a
merged PR its local tip has moved past, and must name it. `--default`
spelled `origin/HEAD` must keep `main`, and `HEAD`, `@`, a sha or `main~0`
must exit 2 with a feature branch checked out. So must an unset or
dangling `origin/HEAD`, even with a `main` present, and a remote ref under
no configured remote or under two nested ones; `up/stream/main` must keep
`main`, and auto-detect must strip exactly `origin` beside a remote named
`origin/release`. An unpushed merge into local `main` must not reap, nor
may `main` when origin/HEAD points under another remote. The check that
DEFAULT_REF is exactly `refs/heads/<DEFAULT>` or `refs/remotes/<remote>/<DEFAULT>`
is a backstop behind the resolution above it, so its mutant removes both.
Two refusals carry no mutant: a dangling origin/HEAD, and a `--default`
that resolves to a commit rather than a branch. Each is refused by two
later checks as well (the resolve check, then the DEFAULT_REF guard or
the exact-spelling check), so removing any one leaves the arm green.
A PR merged into a feature branch, for a live or a deleted branch, must not
reap; the `gh` stub reports a `baseRefName`, `main` unless a row names one.
The E2E arm runs the real `custodian-history.sh` ingest, then reap: a
`gates.jsonl` rewritten under reused cites must be kept, including one that
differs only in `blockers`, `ran` or `verified_by`. `index_upto` writes every
field ingest writes, in ingest's normal form, since the guard compares them,
and each guard field has its own single-field arm and mutant. Ingest must
index `ran` and `task_tool_available` false as false, and the guard must
still match an older index that stored them as null. `--apply` must
archive, never delete: reaped dirs move whole under `.archive/<date>/`, a
second reap of one name lands beside the first, and ingest and reap both
skip the archive. Every fixture repo
sets `origin/HEAD` the way a clone does. The newline case
runs from a decoy working dir holding `bar/`, beside a file named
`x<newline>bar`. The guardrails suite holds the matching ingest fixture,
since it is the one that drives `custodian-history.sh`.

`gh` is a stub on PATH that answers from a fixture table, so the real `gh`
is never called. The absent case sets `GH_BIN` to a missing path rather
than trimming PATH. GitHub-hosted runners come with `gh` installed, and a
PATH trimmed enough to hide it could also hide `git` and `jq`. A failing
stub must produce the same verdict as a missing one.

Two of the exit-2 arms are layered: removing the non-repo or
default-branch check alone leaves a later check that still exits 2. Each was
watched failing with every layer removed. The `HEAD` refusal is layered the
same way over the exact-spelling check, so its mutant removes both. The
miscased spellings (`Main`, `head`, `Origin/HEAD`) resolve on a case-blind
macOS filesystem and fail to resolve on Linux; both must exit 2.

## custodian-skill-lint

Both-directions test for the skill linter.

Standing rule: a new invariant is tested RED (fires on a violating fixture)
AND green (clean fixture passes). This proves each STRUCTURAL check flags its
own violation with the offending file cited, that exit is 1 on any structural
violation and 0 when clean, and — crucially for the two-tier design — that an
ADVISORY-only fixture (over the token budgets, nothing structurally wrong)
still exits 0. Pure bash + jq-free, self-contained fixtures under a temp dir.

## doc-bloat-scan

Both-directions test for the comment-bloat detector.

Every kind fires on a violating fixture (RED) AND the clean fixtures produce
ZERO output (green), in both the C-style and the JSX braced (`{/* … */}`)
spelling. The green side proves no false positive on: a lowercase
single-line comment, a single-line `/** … */`, consecutive braced
one-liners (a `{/*` read as an unconditional block opener would swallow the
code between them into a phantom block), a `// TODO:` marker, a braced
token inside a string, a `https://` URL (the `//` must not read as a
comment), and a comment of exactly 75 chars — the boundary itself, paired
with an exactly-76 line on the red side so the comparison is pinned from
both directions rather than somewhere in the middle.

Three more green shapes carry the block bookkeeping: a block with NO content
line at all, in both the bare and the `*`-only spelling, so that miscounting
an empty body emits a candidate quoting nothing; the braced zero-content
form, whose `*/}` closer has to strip to empty like a plain `*/` does; and a
`{ /*` block scope, which is not a comment opener because the brace does not
abut — the one rule the scanner states twice.

The unterminated fixtures cover the swallow-to-EOF hole: an opener that never
closes used to leave block state set for the rest of the file, so every
later candidate vanished at exit 0. Both spellings appear, each followed by a
candidate that must still be found and a chained second false opener; the
`.ts` one adds an over-75 CODE line that must NOT fire, since that hit came
from inside the phantom block. Only `//`-family candidates can follow one —
anything carrying a `*/` would have closed it instead. On `.ts` that second
opener puts its candidate on opener+1, which is what pins the restart
boundary — everywhere else the first post-opener candidate sits further
down, so an off-by-one there swallowed a real hit and stayed green. The
reverse direction is the tally: a block that CLOSES emits none, and four is
the whole tree's count.

Four fixtures answer to the lexer rather than to the line shapes: a `/*`
inside a `//` comment, a comment inside a multi-line `${…}` substitution,
two lone backticks bracketing a Java text block's opener, and an ordered
PAIR scanned on its own, since one awk run reads many files and the walk's
order is find's. Delete any one and a mutant in
`scripts/custodian-mutation-kill.sh` survives.

GOTCHA: a `TMPDIR` inside a git work tree reds this suite — the walk takes
its `git ls-files` branch and lists no untracked fixture.

Exit is always 0 — the scanner reports, it never gates. Pure bash, jq-free.

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

## loop-counters

Both-directions test for the step-2c counter writer and budget governor.

The writer replaced a hand-edit, and the hand-edit's failure was a dropped
comma that left `run-state.json` unparseable. So the arm that matters most is
the refusal: thirteen malformed or misclassified outcomes — truncated JSON
among them — each exit 2 with the existing snapshot byte-identical and no
`.tmp` left beside it. Every counter the writer reads or writes is checked
before anything is applied, not only the ones this outcome moves: a
fractional, negative, boolean, string or array counter would otherwise be
written back shifted by one or trip a rail on a value that is not a count.
A rail evaluation that errors refuses the same way, so a broken governor
can never print `GOVERNOR: clear`; a jq shim that fails only that call is
the arm.

Eight properties the governor's honesty depends on:

- EVERY COUNTER MOVES BY THE TABLE, PER OUTCOME KIND. A direct fix is a
  corrective but not a dispatched wave; a retry is a dispatched wave but not a
  corrective and keeps its wave's correctives; only a new queue wave resets
  them. Each of those distinctions has an arm, because each is a one-word
  edit to the writer.
- EVERY RAIL IS PINNED AT ITS BOUNDARY, both directions: trips on reaching
  its limit, quiet one short of it. A `>=` turned `>` passes every arm that
  sits far from the limit.
- ALL THREE CORRECTIVE RAILS NEED A GATING FINDING. The wave's one
  corrective is the budget, not a breach; only a second gating finding after
  it is a `rethink`. Likewise the run's sixth corrective shipping clean is clear;
  `max_corrective_waves` trips only when a seventh would be needed, and a
  second scaffolding-only corrective with nothing gating is clear but still
  counted. And a STOP rail tripped beside a rethink wins.
- A RAIL NEVER HALTS ON A UNIT THAT SUCCEEDED. The 25th wave and the 4th
  retry, each shipped, read clear. `max_total_waves` and `max_wave_retries`
  are checked by `--next`, before the dispatch they would refuse: a queue,
  corrective or retry dispatch at the ceiling trips the first, a retry
  dispatch at the limit the second, a queue dispatch never the second, and
  `--next cleanup` neither. Every query leaves the snapshot byte-identical.
- THE CLEANUP WAVE RUNS ONCE. `--next cleanup` reads `skip` over an empty
  `cleanup_batch` or once a `cleanup` outcome has set `cleanup_waves`; the
  reviewer's case, three cleanup rounds on one snapshot, must read clear,
  skip, skip with `total_waves` at 1.
- A RETHINK EARNS ONE RETRY PER WAVE. Outcomes are chained on one snapshot:
  queue, gating crew, gating corrective (rethink), then a gating retry must
  read STOP, as must a gating re-crew after a clean retry. A new queue wave
  resets `retries_this_wave`, so its own rethink earns its own retry.
  `consecutive_no_progress` shares it: three unshipped queue waves read
  rethink, an unshipped retry after them STOP, a net-new retry clear.
- OVERRIDES LAND ON THEIR OWN RAIL. One assertion reads all six limits back
  from the `- budget:` line, so a crossed key mapping reddens; a `budget:`
  line under another heading is ignored; with no flag, the snapshot's own
  repo `CLAUDE.md` is read. A template quoted in a code fence is skipped,
  a fence closes only on a run at least as long as its opener, and a
  second `budget:` line or a zero limit refuses. A CRLF file's fence closes
  too, so its budget line still lands.
- THE RAIL ACTIONS MIRROR THE SKILL. Each tripped rail's printed action must
  appear in its `SKILL.md` governor row, so the two cannot drift apart.

Every assertion was watched fail: 67 declared mutants in
`scripts/custodian-mutation-kill.sh`, one per increment, reset, rail
comparison, rail condition, `--next` kind, override path and refusal
guard, all killed. The first sweep
found 13 survivors. Twelve were one harness bug — a `$?` read after a
command substitution in the check's own description, which made every
counter assertion pass. The thirteenth was the STOP-outranks-rethink guard,
unreachable while the per-wave rail was evaluated first; it is evaluated
last now, so the guard is what decides.

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
happened: every launching case matches the whole argv, so the
`/looper-custodian` payload can't go missing and no flag can be silently
reintroduced while the suite stays green — including the resume launch,
whose own argv is now pinned the same way. The REPO seam is checked the same
way in both directions — it decides the cwd claude runs in, and an
unenterable one must refuse the run, not launch somewhere else.

Both launch sites run `--output-format json` so the wrapper can read the
response's `permission_denials` array — a tool call the allowlist doesn't
cover fails closed but is otherwise invisible (no prompt, exit 0, nothing in
plain text output). A `claude` stub queue lets a case script exactly that
JSON body: one case pins a non-empty `permission_denials` array and asserts
a SEPARATE loud notice fires (`Custodian permission denial` issue, naming
the denied tool) without changing the run's own exit code; its sibling
pins an empty array and asserts silence, so the check doesn't fire on
every clean run.

## skill-body-ceiling

Both-directions test for the body-ceiling check.

The failure that matters is a check that stops checking: a ceilings file it
cannot read, a row it skips, a comparison that never fires. Each of those
looks exactly like a clean run from the outside, so the shapes are pinned in
this suite rather than the happy path alone.

A row whose name carries a slash is a repo-relative path rather than a skill
name, which is how an agent gets a ceiling — agents are flat files with no
`skills/<name>/SKILL.md` shape to infer. Both directions of that are pinned:
the path resolving, and the path dangling.

## spec-load

Both-directions test for the spec-load instrument, which reports what each
entry point loads before it reads a line of the code under work.

The arm that matters is MISSING. This instrument exists to prove later waves
cut what they claim, so its own failure mode is reporting a saving it never
measured: a renamed file quietly leaving the sum, or a baseline entry the
manifest stopped covering. Both are exit 2, and both are asserted here in
each direction. The mutant that turns the missing-file stop into a skipped
row was run against this suite and takes two assertions red with it.

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

## usage-window-probe

Producer-side test for scripts/usage-window-probe.sh, the probe
scripts/looper-custodian-cron.sh reads at run start.

The consumer's suite came first, and its probe fixtures are honest captures —
but a capture pins only what the probe emitted the day it was taken. Renaming
`five_hour` to `5h` in the probe left the whole battery green while every real
run read `unread no_utilization` and launched unguarded. This suite is the
other side of that seam.

NO NETWORK, AND NO SEAM. The probe makes a live authenticated call, and it
needed no `${VAR:-default}` transport seam to reach: every non-deterministic
input it has is already controllable from the environment. Each case runs the
real script, unmodified, under `env -i` with

- PATH sealed to a per-case dir, so `security(1)` is ABSENT rather than stubbed
  on the dotfile arms, and the real curl is unreachable from every arm
- a stub `curl` that prints a recorded header block and records its own argv
- HOME pointed at a fixture credential blob holding a fake token
- `expiresAt` written relative to `date +%s`, so the freshness arms cannot rot

Rejected: a `PROBE_CURL` seam (buys nothing the sealed PATH does not, and adds
a production line whose only caller is a test); a stub HTTP server (a listener,
a port and a race, for no gain); extracting the parser (a rewrite, and it would
test the extract rather than the probe).

A stub is written only after `rm -f`. `seal()` leaves a SYMLINK in that slot,
and `>` through a symlink truncates the system binary it points at instead of
shadowing it — which is how the first draft's `parse_failed` case quietly went
on using the real python3.

FIXTURE PROVENANCE — one live capture, 2026-08-21, of the REAL response header
block, taken by running the real probe under a `curl` shim that tees its own
stdout. One API call, the probe did its own auth, and no token was recorded.
Kept verbatim: CRLF endings, and the CONNECT preamble the local proxy added,
which doubles as the case for skipping a line that carries no colon. Variants
are exact-string edits of that block, and `hdrs()` refuses an edit matching
nothing — a no-op edit silently re-tests the capture.

Observed live on it: `allowed` on both windows, `representative-claim:
five_hour`, and `overage-status: rejected` sitting on a header the probe must
NOT read, which is what makes the captured case discriminating. NOT observed
live: `rejected` on a window status — the consumer suite says the same — and
any representative claim other than `five_hour`, so the pass-through arm uses
a visibly synthetic value rather than inventing a vocabulary.

Three emitters, three shapes, each pinned byte for byte:

```
success               json.dumps spacing; read_ok, source, five_hour,
                      weekly, representative
emit_unreadable       a bare printf, no space anywhere
no_ratelimit_headers  json.dumps again — spaced, and NOT the printf shape
```

The reason enumeration is DERIVED, never listed: the suite records which reason
each case observed and compares that set against the literals grepped out of
the probe, so a seventh reason with no case reddens instead of passing
unnoticed.

The SEAM arm reads the consumer suite's two captured fixtures and compares
their key paths against what the probe emits today. Nothing else in the repo
compares the two, and that gap is what put this suite here.

Deliberately over the ~100-line refactor bar. Every case is welded to the one
captured block — the goldens are that capture's own numbers and the variants
are edits to it — so splitting the emitter cases from the credential cases
would leave the capture in one file, half its goldens in another, and the
sealed-PATH harness that makes any of it hermetic in a third. The bulk is
arithmetic: a case costs five lines and asserts four things. Trim its prose
before reaching for its code.

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

## wave-queue-dag-audit

Both-directions test for the wave-queue DAG invariant audit.

The audit has three possible outcomes per arm — ok, VIOLATION, and a decline —
and the whole suite exists because two pairs of those are easy to confuse.

- A DECLINE IS NOT A PASS. Eight of the sixteen real snapshots on disk predate
  the documented `queue[]` shape, in four separate eras: no `queue` key at all,
  entries keyed `id: "wave-1"`, entries keyed `n` with values like `"8a"`, and
  an empty `queue[]` with the wave records in top-level `wave_N` keys beside a
  `goal_contract` that is a bare array of integer-id asks rather than
  `{asks: […]}`. Each has an arm, because removing that guard makes the
  `linklater` snapshot fail its every-entry-has-a-wave-number arm — one
  violated arm of three, carrying a count of 17 entries, not 17 separate
  violations — which is what the suite's legacy arms exist to catch.
- A DECLINE IS NOT A VIOLATION EITHER, so the exit code has to separate them:
  1 for a real disagreement, 2 for an arm that could not be settled. A
  snapshot that both violates and declines exits 1, because a disagreement is
  actionable and a gap is only a reason to go looking. That pair has an arm.
- THE STANDING NOT-EVALUABLE IS NOT A DECLINE. Fourteen of the sixteen real
  snapshots persist no dependency edge — the schema does not ask for one, and
  scope prints `depends on:` as prose (`docs/wave-queue-dag-audit-findings.md`)
  — so counting the absence as a declined arm would make most clean runs exit 2
  and drain the code of signal. It prints `n/a` and stays out of both tallies,
  and an arm asserts that a fully conforming snapshot exits 0 with no
  INCOMPLETE.
- THE EDGE ARM REALLY EVALUATES, AND REAL DATA REACHES IT. `carn/phase/1a`
  persists `depends_on` as arrays on all five entries; the arm checks strict
  source-before-target and rejects a self-edge. Six arms — earlier-wave edge,
  later-wave edge, self-edge, the five-entry multi-edge graph that snapshot
  actually carries, a second edge in an entry whose first edge is fine, and the
  `depends`/`blocked_by` spellings of the same field — since an arm nobody
  watched fire is indistinguishable from an arm that returns "no edges"
  forever. The last two exist because the arm reads every edge and four field
  spellings, and a version reading only the first edge, or only two spellings,
  passed everything the suite asserted before them.
- A FIELD IN THE WRONG TYPE DECLINES, IT DOES NOT CRASH. `carn/phase/1c`
  persists the same key as prose (`"none"`, `"wave 1"`), which iterated as an
  array exits 5 — outside the script's own 0/1/2 contract — and in a batch run
  silently drops every snapshot after it. Two arms: the prose value declines,
  and a good snapshot listed after a prose one is still reported.
- THE SAME GUARD COVERS `goal_contract` AND `closes`, AHEAD OF THE DATA. Its
  arms are the only ones here with no snapshot behind them: nothing on disk
  lists bare ids where ask objects belong, or a `closes` that is not a list.
  They cost the same two failures anyway — a contract of bare ids exits 5 on
  `.id` and takes the rest of the batch with it, and a scalar `closes` reports
  every ask unclaimed, which is a VIOLATION the reader has no way to tell from
  a real one. Arms for both, plus the prose-`asks` spelling and the batch cost.
- A DECLINE NAMES THE SHAPE IT ACTUALLY CANNOT READ. Two arms, for two ways
  the guard misnamed what stopped it. An `asks` map keyed by id declines on the
  CONTAINER, because its values are objects and the element wording said they
  were not; and a `closes` that is `null` does not decline at all — null closes
  nothing, which the claim arms already read correctly, so counting it
  unreadable turned a right answer into a SKIP. A declared mutant pins each.
- CONTIGUITY IS A SET EQUALITY, NOT A CEILING. Differencing `1..max` against
  the observed set in one direction alone lets a wave numbered 0 or -1 through,
  because neither leaves a hole below the maximum. Both directions are
  differenced, and two arms hold the low end the one-sided form never had.
- AN ASK ID IS OPAQUE. The ids used to reach the arms comma-joined into one
  string and split back apart, so an id carrying a comma arrived as two asks
  nobody declared — a false unclaimed-ask and a false dangling-id at once. They
  travel as JSON now, and an arm pins it.
- THE CORPUS IS DISCOVERED, NOT LISTED. `--census ROOT` walks for
  `*/local/loops/*/run-state.json`, because a hand-written list of repos
  silently omits the next one. Three arms: nested snapshots are found, a
  `run-state.json` outside `local/loops` is not, and a root with no snapshot
  exits 2 instead of quietly auditing something else.
- THE ARM COUNT IN THE HEADLINE IS ASSERTED. It is what separates "five arms
  agreed" from "one arm ran". Deleting the contiguity arm from the audit
  reddens eight assertions, three of them count assertions.

Self-contained: every fixture is written by the suite, including a throwaway
git repo with two real commits for the execution-order proxy arm — inverting
the two shas is how the RED half of that arm is reached, and listing the
entries in the reverse of their wave order is what pins the sort the arm reads
them through. Nothing reads gitignored `local/`.

## loop-unanimity-audit

Both-directions test for the unanimous-verdict backing audit.

The audit's whole output is a count, and a count of 0 is the answer nobody can
check by eye. So every exclusion arm is paired with the fixture it excludes,
and the positive control comes first:

- THE POSITIVE CONTROL LEADS, AND ITS MUTATION FOLLOWS. Three reviewers, all
  clean, all `llm` — found, exit 1. Flip one line to
  `verified_by: "executable"` and the whole group clears, exit 0. Without that
  pair, "5 of 96" would rest on nobody having watched the detector fire.
- AN EXCLUSION IS NOT A CLEAN RESULT. Four different reasons drop a group
  before it can be a finding — one reviewer, the same agent twice, a rollup
  line (`ALL-SIX-ENUMERATED`, `the-chemist/the-improver`), and a legacy-era
  record with no `verified_by` key at all. Each is asserted on its own counter
  in the report, not just on the exit code, because all four exit 0 and only
  the counters say which one happened.
- LEGACY-ERA IS THE ONE THAT COSTS THE MOST IF IT LEAKS. 33 real groups sit in
  it against 5 findings, so an arm asserts the modern-era count stays 0 when
  the fixture predates the field. Making findings ignore the era reddens it.
- THE CREW PREDICATE IS A SUBSTRING MATCH ON PURPOSE. `crew-final` and
  `final-crew` are asserted to count, because the index holds a dozen crew
  spellings and `== "crew"` would make most historical crew coverage invisible
  — the failure `state-schemas.md` documents. A paired arm asserts
  `executor-handback` does NOT count, so the substring is not just permissive.
- A NOT-RAN LINE IS DROPPED BUT STILL REPORTED. Two arms: the finding shows
  `2 reviewer(s) ran of 3 crew line(s) logged`, and the corpus line reports the
  drop. Two of the five real findings are unanimities of a minority, so a
  suite that let the drop go unprinted would hide the most interesting half of
  the result.
- DEDUP NEEDS A COUNTER, NOT A GROUP COUNT. Feeding the same wave through both
  corpus arms yields one group whether or not dedup runs, so the first version
  of that arm survived deleting the dedup entirely. It now asserts
  `2 deduped · 2 crew` against 4 input lines, and deleting the dedup reddens
  it.
- A COLLISION HAS A WINNER, AND IT IS THE LIVE ROW. The index's copy of a gate
  line is a snapshot that can predate fields the file now carries, so an arm
  feeds an index row with no `pass` and no `verified_by` against a live row
  carrying both, and asserts the survivor is the live one — on the real corpus
  eight `linklater/main` cites collide and seven of them were losing
  `pass: "final"` to their snapshots. Eight is the collision count, seven the
  loss count: the eighth is a `pr-finalization` row carrying `pass: null` on
  both sides, which loses nothing either way. Preferring the index instead
  reddens it.
- THE FALLBACK DEDUP KEY IS A SEPARATE PATH AND GETS ITS OWN ARM. Census rows
  always synthesise a `cite`, so only a cite-less index row reaches
  `repo|branch|kind|agent|summary`. Three such rows are asserted to collapse to
  two, and a paired arm changes one `summary` and asserts they stay three —
  dropping `summary` from the key reddens the second.
- THE ERA SUB-BUCKETS MUST PARTITION THEIR PARENT. A group whose lines are
  mixed — some carrying `verified_by`, some not — is neither all-legacy nor
  all-modern, so it used to land in `t1_zero` and in neither sub-bucket, and
  33 + 5 = 38 summed only because no real group was mixed. A third `mixed-era`
  bucket now exists, and an arm builds all three group kinds at once and
  asserts the three sub-counts sum to `t1_zero`.
- AN UNREADABLE SUBTREE IS A WARNING, NOT A SILENT DROP. `find`'s stderr and
  exit status used to be discarded, so a mode-000 directory removed its repo's
  crew lines from the corpus with nothing said. An arm chmods a fixture repo to
  000 and asserts the warning fires, and a paired arm asserts a fully readable
  census warns about nothing — that second half is pinned by a declared mutant
  forcing the warning permanently on. The fixture refuses to run rather than
  pass if `chmod 000` does not actually block the current user. Two limits are
  part of the claim rather than exceptions to it. The warning carries only what
  `find` itself reports, and that is platform-dependent: measured against BSD
  `find` on macOS, modes 111 and 000 are reported, but a read-but-not-
  traversable directory at mode 444 loses its whole subtree at exit 0 with
  nothing on stderr — silently, the very shape the warning exists to end.
  Whether another platform's `find` reports 444 was not measured. So this
  closes the silent drop for the permission shapes the running `find`
  surfaces, not for every shape. And the arm's companion
  `census 2 line(s) from 1 file(s)` clause is fixture sanity, not a pin: it
  reads the same on both sides of the change it shipped with.
- A NULL AGENT IS A ROLLUP. The rollup predicate has four arms and the null one
  had no fixture; it now has one, asserted on the `rollup-agent` counter and on
  the modern-era count staying 0.
- AN ARCHIVED GROUP IS NOT AUDITED. The positive control's rows, re-cited
  under `local/loops/.archive/`, exit 0 with no finding, since decision 32
  never re-audits archived gate lines. A declared mutant drops the filter.

Self-contained: every fixture is written by the suite into a temp dir, and the
census arm is pointed at a temp root. Nothing reads gitignored `local/` or the
real history index.

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
