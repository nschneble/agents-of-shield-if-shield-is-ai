# Two shadow-tested review formats

Shadow test of looper-custodian issue #89 findings E-2 and E-5 against this system's own review
history. E-2 proposes a structured premises / code-path-trace / conclusion format for verification
steps that cannot execute. E-5 proposes a three-tag finding format — AGREE, DISAGREE_EVIDENCE,
DISAGREE_CONCERN — in place of free-text reviewer pushback.

Neither format is adopted here. Both are applied after the fact to work this system already shipped,
and scored against what the original step actually concluded. Everything below is reconstructed from
records on disk across `~/Developer/Repos`:

```
find ~/Developer/Repos -path '*/local/loops/*' -name 'wave-*.jsonl' | wc -l   # 90
find ~/Developer/Repos -path '*/local/loops/*' -name gates.jsonl | wc -l      # 12
```

That corpus is live and includes this run's own records, so both counts grow while the run does.
Every figure below either names the command that produces it or scopes that command to a fixed set of
waves, and where a figure is a transcript of one replay it says so.

## Verdicts

**E-2, structured verification: CONFIRMED very narrowly, for one field, and with a demonstrated
failure mode of its own.** On four real review steps that reached a conclusion about code no test
exercised, the structured format agreed with all four verdicts. What it added is thinner than an
earlier revision of this document claimed, and is set out in [the scorecard](#scorecard): one blind
case gained a genuine but modest strengthening, one blind case gained a correct new premise attached
to a conclusion that turned out to be false, the held-out case gained nothing, and the case that
gained most was contaminated. Its value is not accuracy — it is that the PREMISES field forces the
reviewer to enumerate the inputs on a path instead of reasoning inside a window it drew itself, and
that field is the only part of the template this evidence supports. The rest of the template is where
case 3 went wrong: it dressed one under-powered probe as a proof, and made a wrong conclusion look
derived. It pays where a claim spans several paths or several inputs and does not pay where one grep
settles the question, so the rule worth having is conditional, not universal — and it is not a
substitute for executing the thing.

**E-5, three-tag findings: NOT CONFIRMED.** This system already has a three-token discrete finding
field, `outcome` (`refute` / `batch` / `promote`), already scoped per-reviewer with no aggregation.
Across 126 crew lines, 33 carry a legal token, 13 carry an off-schema one, and 80 carry none —
because unlike `kind`, the `outcome` enum is documented and not enforced. Retagging 13 real findings
from one reviewer, 2 fit no tag at all, and the 2 that mapped without strain were the ones
contradicting something the executor had actually written down. The binding constraint here is an
unenforced field, not a missing vocabulary.

## Method, and what is being tested

Both papers were fetched, not recalled.

E-2 sources arxiv 2603.01896 (Ugare & Chandra, _Agentic Code Reasoning_,
https://arxiv.org/abs/2603.01896). Its patch-equivalence template has six fields: DEFINITIONS,
PREMISES, ANALYSIS OF TEST BEHAVIOR, COUNTEREXAMPLE, FORMAL CONCLUSION, ANSWER. The claimed
78% → 88% / 93% band is for one task, patch equivalence, defined as "Two patches are equivalent
modulo tests if and only if executing the repository's test suite (F2P ∪ P2P) produces identical
pass/fail outcomes for both patches" — 170 curated pairs and 200 real-world pairs. The third field is
filled **per test**. The paper also states it scores "only the final binary answer", not whether the
reasoning steps are themselves correct.

**The four case write-ups below rename two of those fields**, and say so here rather than in a
footnote: ANALYSIS OF TEST BEHAVIOR appears as EXECUTION TRACES, and COUNTEREXAMPLE as
COUNTEREXAMPLE-OR-PROOF. ANSWER is dropped as redundant with FORMAL CONCLUSION outside a benchmark.
The first rename is not cosmetic — "analysis of test behavior" is anchored on tests by name, which
makes applying it to steps with no tests a larger re-siting than the section below originally
admitted.

E-5 sources arxiv 2608.18167 (Qiu & Gill, _Adversarial Review: Structured Disagreement for Grounded
Agentic Code Review_, https://arxiv.org/abs/2608.18167). The three tag names are verbatim. In the
paper they are the **critic's**, applied to the **reviewer's** findings, in a serial
main-agent → reviewer → critic loop over a frozen artifact. The false-consensus mode it counters has
two halves: over-decomposition, where the critic confirms weak signals into thin fabricated findings,
and yielding-to-rebuttal, where the critic drops a real bug on a confident rebuttal carrying no code
evidence.

Both proposals re-site their source. E-2's third field is anchored on an existing test suite — by
name, not merely by context — and is here applied to steps that have none. E-5's tags move from
critic-tags-reviewer to reviewer-tags-artifact. The verdicts above are verdicts on the re-sited formats, because the re-sited
formats are what E-2 and E-5 propose. Where the re-siting is what breaks, the report says so.

Nothing in E-5 is aggregated across reviewers, and nothing below builds or proposes aggregation. The
crew here is domain-partitioned; a second reviewer's finding is evidence about a different domain,
not a second vote on the same one.

## E-2: structured verification on no-test-execution reviews

Four real review steps, each of which concluded something about code that no test exercised. All four
are read with `git show <sha>:<path>` from `~/Developer/Repos/carn`. Nothing was checked out and no
working tree was touched.

Three of the four are written up below; the fourth was held out and is reported in the scorecard
section, because it was run only after the first three were on the page.

Two of the three written up were run **blind**: the five template fields were written against the
blob as it stood at the reviewed commit and saved, and only then was later history consulted. The
third was already contaminated — its later history was read during research, before the trace — and
is marked as such. The contaminated case is illustrative only; the verdict rests on the blind and
held-out cases.

### Case 1 — the semaphore slot window (CONTAMINATED)

carn `phase/1b` wave-4c, reviewed 2026-08-25 at commit `56e2a69`, "Phase 1b: free the git semaphore
slot when spawn throws". The wave's own verify ran 29/29 tests and mutation-proved the new one. The
review then concluded, verbatim:

> warning: guard covers spawn() only; setTimeout/addEventListener/Promise-executor between the try
> and handler attachment stay unguarded (judged non-throwing)

**DEFINITIONS.** D1: `spawnGit` holds a slot from the moment `await semaphore.acquire()` resolves
until exactly one `semaphore.release()` runs. The slot is LEAKED iff some reachable path from a
resolved acquire to a terminal state — return, throw, or `done` settling — runs no release.

**PREMISES.** Generated by a rule stated before the answer: enumerate every statement between the
resolved acquire and each terminal state, and every path INTO acquire, and ask of each whether it can
throw, return, or suspend forever.

- P1. At `56e2a69` the `Semaphore` class is inline in the same file. `acquire()` takes no signal, and
  a waiter parked in `#waiting` has no exit but a later `release()` shifting it.
- P2. `release()` either bumps `#free` or hands the grant to the head waiter. Never both.
- P3. After a successful spawn, `finish()` is the only release site, and it runs only from
  `child.on("error")` or `child.on("close")`.
- P4. `new Promise(executor)` does not propagate a synchronous executor throw — it rejects. A throw
  there leaks the slot with no exception the caller can attribute it to.

**EXECUTION TRACES.** Nine paths, per path rather than per test:

| #   | Path                                      | Slot                                                                 |
| --- | ----------------------------------------- | -------------------------------------------------------------------- |
| T1  | aborted before acquire → `throwIfAborted` | never taken                                                          |
| T2  | abort while queued in `#waiting`          | acquire never settles; caller waits for an unrelated release         |
| T3  | grant and abort in the same tick          | aborted-check releases                                               |
| T4  | `spawn()` throws synchronously on a NUL   | catch releases — this is what the wave fixed                         |
| T5  | `setTimeout` throws                       | not reachable; it validates the callback only, and that is a literal |
| T6  | `addEventListener` throws                 | not reachable under the `AbortSignal` type                           |
| T7  | Promise executor throws                   | not reachable; `child.on` takes function literals on a real emitter  |
| T8  | child emits neither `error` nor `close`   | the timer kills it, `close` fires                                    |
| T9  | the aborted-check's own `release()`       | present and correct, and no test reaches it                          |

**COUNTEREXAMPLE-OR-PROOF.** No counterexample to D1 exists inside the window the review named. T5,
T6 and T7 are each unreachable, so "judged non-throwing" is correct.

**FORMAL CONCLUSION.** The review's claim is true and its window is not the right window. The
enumeration rule generates two cases the window excludes by construction, both upstream of the `try`:
T2, a liveness defect in `acquire`, and T9, a correct-but-unpinned release arm.

**What actually happened.** Both were real and both were found later by other means. T9 was found the
same day by the-chemist's crew pass on carn `phase/1b` wave 9, which logged `refute: proven surviving
mutant at src/git/spawn.ts:79-83 -- semaphore leak on abort-while-queued arm ... mutation-confirmed
(deleting release() there leaves all 6 tests green)`, and was paid for by corrective `d815b36`. T2
was filed as carn issue #8 and fixed 2026-09-03 in `d7ccfc9`, which gave `acquire` a signal and made
a queued waiter splice itself out and reject on abort.

**Contamination.** `d7ccfc9` and the wave-9 gate line were both read during this wave's research,
before the trace was written. This case cannot show the format would have found them. What a reader
can check independently is that the enumeration rule above is stated without reference to the answer,
and that applying it mechanically yields T2 and T9 while the review's window cannot.

Outcome: **agrees, and adds** — with the caveat that the addition is not blind.

### Case 2 — the invisible fixture (BLIND)

carn `phase/1d` wave-14, reviewed 2026-08-27 at commit `626372e`. The review concluded, verbatim, as
one of three warnings:

> .fixture files are invisible to doc-bloat-scan

**DEFINITIONS.** D2: a file is VISIBLE to the scan iff bytes from it can reach the awk finder.

**PREMISES.** All from `scripts/doc-bloat-scan.sh` in `agents-of-shield-if-shield-is-ai`, unchanged
since that repo's `c680461` (2026-08-20) and so the same file the review reasoned about. The scan
lives in this repo; the fixture it cannot see lives in `carn`.

- P1. `EXT_RE='\.(ts|tsx|js|jsx|mjs|cjs|c|h|cc|cpp|hpp|hh|go|java|swift|rs|kt|kts|scala|cs|m|mm)$'`
  — anchored at end of record.
- P2. `scan_files()` pipes the NUL-delimited path list through `grep -zEi "$EXT_RE"` before `xargs`
  reaches awk. Nothing that fails the filter is scanned.
- P3. `main()` sends both branches through `scan_files` — a directory walk and a file named directly
  as an argument alike.
- P4. The file is `test/fixtures/markdown-raw-position.ts.fixture`. It is tracked, so the `git
ls-files` walk emits it; its final extension is `.fixture`.

**EXECUTION TRACES.** Two entry paths, both to the same gate. A walk over the directory emits the
path, which then fails P1 at P2. Naming the file directly as an argument emits the path, which then
fails P1 at P2. `.ts` occurs in the name but not at the end, and `$` requires the end.

**COUNTEREXAMPLE-OR-PROOF.** No counterexample. Both entry paths are blocked by the same filter.

**FORMAL CONCLUSION.** The claim holds, and holds more strongly than stated: the file is invisible
even when named directly, not merely skipped by a walk.

**What actually happened.** Differential oracle, same bytes under two extensions:

```
git show 626372e:test/fixtures/markdown-raw-position.ts.fixture > fx/markdown-raw-position.ts.fixture
cp fx/markdown-raw-position.ts.fixture fx/control.ts
scripts/doc-bloat-scan.sh fx/markdown-raw-position.ts.fixture   # 0 candidates
scripts/doc-bloat-scan.sh fx/control.ts                         # 2 candidates
```

The `.fixture` copy yields nothing. The `.ts` copy yields `capitalized-slash` at line 3 and
`stacked-slashes` at line 1. So the invisibility is not hypothetical: that fixture's header really
does carry two candidates the scan cannot see. Neither is an `over-75`.

The trace adds one thing the free-text warning did not carry. This repo's standing instruction is
that new comments default to zero, **proven via** the scan. For a `.fixture` file that proof cannot
be produced by the named tool, so a zero there means "not looked at", not "nothing found". The
warning says the tool is blind; the trace says what the blindness costs the rule that depends on it.

Outcome: **agrees, and adds.**

### Case 3 — the reachable interpolation (BLIND)

carn `phase/1b` wave 9, reviewed 2026-08-25 at commit `375c2b1`. The review concluded, verbatim, as
one of two warnings:

> ${error} interpolation still reachable but repo names are charset-validated before any throw

The concern class is log injection: attacker text reaching `console.error` and carrying newlines or
terminal escapes into operator logs.

**DEFINITIONS.** D3: a sink is INJECTABLE iff some attacker-controlled input reaches it carrying a
raw newline or control byte.

**PREMISES.** Enumerate every attacker-controlled input on the path to the sink, not only the one the
warning names.

- P0. The file carries **four** `${error}` interpolation sinks at `375c2b1` — `server.ts:74`, `:118`,
  `:129` and `:135`. Only `:118` is traced below. That narrowing was not stated when the trace was
  written and is not justified by anything in the warning, which names no line.
- P1. The sink is `src/ssh/server.ts:118`, `console.error(\`ssh: ${ip} running ${service} failed,
  ${error}\`)`, in the `.catch`on`handleExec`.
- P2. `service` comes from `commandPattern`, one of two literals or a fixed string.
- P3. Repo names pass `namePattern = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/` in `resolveRepo` before
  either `db.$queryRaw` or `createRepo` can run. The warning's stated premise is true.
- P4. **A second attacker-controlled input exists, and the warning does not name it.** `gitProtocol`
  is assigned in `onSession` as `gitProtocol = info.val` straight from the SSH env request, with no
  validation of any kind, and flows through `serve` → `spawnGit` → `childEnv` into the child's
  environment. The wave-4c commit message says as much in its own words: "ssh2 passes an env request's
  value through unfiltered into GIT_PROTOCOL".
- P5. A NUL in that value makes `spawn()` throw `ERR_INVALID_ARG_VALUE` synchronously, and Node builds
  that message by `util.inspect`-ing the offending value into it.

**EXECUTION TRACES.** Four throw paths reach the `.catch`:

| Path                                   | Carries attacker text?                               |
| -------------------------------------- | ---------------------------------------------------- |
| `resolveRepo` → `db.$queryRaw` rejects | only a charset-validated name (P3)                   |
| `createRepo` rejects                   | only a charset-validated name (P3)                   |
| `spawnGit` → `signal.reason`           | a DOMException with fixed text                       |
| `spawnGit` → `spawn()` sync throw      | **yes** — the raw `gitProtocol` value, via P4 and P5 |

**COUNTEREXAMPLE-OR-PROOF.** The fourth path is a counterexample to the warning's stated reason, and
whether it is also one to its conclusion turns on P5's escaping behavior. The original probe, on node
v26.8.2 with a payload of `version=2`, a newline, a fake log line and two SGR escapes:

```
TypeError [ERR_INVALID_ARG_VALUE]: The property 'options.env['GIT_PROTOCOL']' must be
a string without null bytes. Received 'version=2\nFAKE-LOG-LINE\x1B[31mred\x1B[0m\x00'
```

Raw newlines in the message: 0. Raw ESC bytes: 0. That probe's payload is 36 characters, and **the
result does not generalize past 76.**

**CORRECTION — the conclusion this section originally drew is false.** Re-probed across payload
lengths on the same node build. `n=64` gives a 76-character value and `n=65` a 77-character one:

```
node -e 'const f=p=>{try{require("child_process").spawn("git",["--version"],{env:{GIT_PROTOCOL:p}})}
catch(e){return e.message}};
for(const n of [64,65,66,300]){const p="version=2\nF"+"A".repeat(n)+"\x00";
console.log(p.length,(f(p).match(/\n/g)||[]).length)}'      # 76 0 · 77 1 · 78 1 · 312 1
```

Once the inspected string **both** contains a `\n` **and** reaches 77 characters — counting the NUL
that triggers the throw — `util.inspect` stops rendering it as one quoted literal and renders it as a
multi-line concatenation, breaking at each escaped newline. Every one of those breaks is a REAL
newline in the error message. The boundary is exactly 77 and does not move with where the newline
sits: a value whose only newline is its last character behaves the same as one whose newline is its
first. A payload carrying three newlines produces three. A payload carrying none produces zero at any
length tested up to 2000. The escaping is per character and never lapses, so the attacker's own `\n`
and ESC bytes stay escaped; what changes is that `util.inspect` adds newlines of its own, at
positions the attacker chooses by padding:

```
... Received 'a\n' +
  'FAKE-LINE-ONE\n' +
  'FAKE-LINE-TWOccc…\x00'
```

Two things follow. Under D3 as written — a sink is injectable iff attacker-controlled input reaches
it carrying a raw newline — **the sink is injectable**, and the section's stated conclusion is wrong.
Under the concern class the warning was actually about, log line forgery, it is not: every injected
line is bracketed by `  '` and `\n' +`, so an attacker can start a new physical line in the operator
log but cannot control how it begins or ends. The honest reading is that D3 was drawn too coarsely
for the question and the trace then answered D3 rather than the question.

A 300-character payload with no newline in it produces zero raw newlines, which is why the wave's own
adversarial check — an unseen 300-char payload — passed. The payload was longer than the threshold
and missed the other half of the condition. A single probe that varies one dimension is not a proof
however formally it is laid out, and the template's COUNTEREXAMPLE-OR-PROOF heading is what made this
one read as settled.

**FORMAL CONCLUSION.** The review's verdict is right about log injection and its stated reason does
not support it: the input that reaches the sink is not the repo name, and is not charset-validated at
all. What the structured trace contributes that survives is P4 — a second, wholly unvalidated
attacker-controlled input the warning never named. What it contributes that does not survive is the
proof it attached to it.

Outcome: **agrees on the verdict, contradicts the reason, adds one correct premise, and asserts one
false one.**

### Scorecard

| Case                     | Blind    | Verdict | Reason          | What the format added                                               | Holds up           |
| ------------------------ | -------- | ------- | --------------- | ------------------------------------------------------------------- | ------------------ |
| 1 — semaphore window     | no       | agrees  | agrees          | two cases outside the window, both later real                       | yes, but not blind |
| 2 — invisible fixture    | yes      | agrees  | agrees          | invisibility by both entry paths, and two real candidates behind it | yes                |
| 3 — reachable `${error}` | yes      | agrees  | **contradicts** | a second unvalidated input (holds) + an escaping proof (**false**)  | half               |
| 4 — unimported `db.ts`   | held out | agrees  | agrees          | **nothing** — see below                                             | n/a                |

Four for four on verdicts. The format did not overturn a single conclusion, which is the honest
headline: on this evidence it is not a defect-finder. Case 3's row carries one asterisk the column
cannot hold — the trace agrees with the REVIEW's verdict, that operator logs are not forgeable here,
while contradicting its own D3, under which the sink is injectable. The review was right and the
template's definition was too coarse to say so.

The "what it added" column is the one that matters and it is thin. Exactly one blind case — case 2 —
produced an addition that is both new and correct, and it is a strengthening of a claim the free-text
warning already made rather than a correction of it. Case 3 produced one correct new premise and one
false conclusion in the same section. Case 4 produced nothing. The case that produced most, case 1,
had read the answer during research and says so.

### The held-out case, which narrows the claim

Case 4 was not part of the write-up. It was run at verify time against a case the report did not
contain, to test whether the pattern in the first three generalizes — and it does not, so the claim
above is narrower than three cases alone would have supported.

carn `phase/1a` wave-4, reviewed at commit `9132820`. The review concluded, verbatim, as one of three
warnings: "db.ts unimported at runtime so app never proves DB reachability - correct per brief but
brief prose says otherwise". The premises are three lines: `src/index.ts` imports `./app.js` and
`./config.js`; `src/app.ts` imports `fastify` and `./routes/health.js`; and `git grep -n 'db\.js'
9132820 -- src/` returns no hits at all. The trace is one walk over three nodes, ES module side
effects run only on import, so `src/db.ts` never executes and a boot cannot prove reachability. The
claim holds and the structured format contributes nothing the original sentence did not already say.

That is the useful negative result. The format earns its cost where a claim spans several paths or
several inputs — case 1's nine paths, case 3's four throw sites and two attacker-controlled inputs —
and earns nothing where the claim is a single graph fact one grep settles. A blanket "structure every
execution-free verification" would spend the format on case 4 to buy the frame corrections in cases 1
and 3.

What it changed in cases 1 and 3 was the FRAME — case 1's window excluded the two cases that
mattered, case 3's reason named the wrong input. Both failures are the same shape, and it is the
shape the PREMISES field exists to prevent: a free-text reviewer reasons inside a boundary it drew
itself and never has to say where the boundary is, while the template makes the boundary a field
somebody else can read. That is the whole of what this evidence supports, and it is one field of six.

**The rest of the template did harm in the one case where it was load-bearing.** Case 3's
COUNTEREXAMPLE-OR-PROOF section ran one probe, at one payload length, and wrote its result as a
settled fact under a heading that says "proof". The claim was false at any payload of 77 characters
or more. A free-text reviewer writing "I checked a short payload and saw no raw newlines" would have
been easier to doubt. Structure is not evidence, and a template that supplies a slot labelled PROOF
invites filling it with the strongest available reading of whatever was actually run. The PREMISES
field ran the other way in the same case: it is what surfaced `gitProtocol`, which is real.

Two caveats bound all of this. The paper scores a binary answer against ground truth and reports
accuracy; there is no binary ground truth here, so these cases are scored three ways — agrees, adds,
contradicts — and no accuracy number is claimed or comparable. And four cases from one repo is not a
sample; it is four cases, of which one was contaminated, one was half wrong, and one was blind and
productive.

## E-5: three-tag findings on one reviewer, three waves

the-chemist, over the first three shipped waves of this run — the A5 wave (`e859fc5`), the A1 wave
(`ea69348`) and the A6 wave (`f78c19e`). Four gate lines and 13 batched findings, all verbatim on
disk. Both commands below are scoped to those three waves; unscoped they select the whole run, which
kept going after this was written:

```
jq -r 'select(.agent=="the-chemist" and (.wave|IN(1,2,3))) | [.wave,.pass,.blockers] | @tsv' \
  local/loops/investigate-custodian-89-research-findings/gates.jsonl
jq -r '[.cleanup_batch[] | select(.agent=="the-chemist" and (.wave|IN(1,2,3)))] | length' \
  local/loops/investigate-custodian-89-research-findings/run-state.json
```

Every finding below gets exactly one tag, or `NO FIT` with the reason.

### The retag

**The tags need an object, and nothing states one.** In the source paper the object is fixed: the
critic tags the reviewer's flag, so AGREE and DISAGREE have something specific to be about. Re-sited
onto a crew reviewer, the object has to be supplied. The 13 findings split 10 `test-coverage` to 3
`docs` (`jq -r '.cleanup_batch[] | select(.agent=="the-chemist" and (.wave|IN(1,2,3))) | .class'`),
and that split is where the difficulty shows. Nine of the ten coverage findings take a different tag
under each of two candidate objects:

- **Object A, "the change is correct."** All nine become AGREE — which is true, the chemist's verdict
  on two of those waves was `CLEAN` with 0 blockers — and the entire content of the finding is lost.
  The tag carries none of it.
- **Object B, "the change is adequately tested."** All nine become DISAGREE_EVIDENCE — and now the
  reviewer's own `CLEAN` wave verdict is contradicted by its own tags.

**That flip is weaker evidence than it looks, and the reason is worth stating.** Object A is not the
chemist's object. "The change is correct" is `the-diamantaire`'s domain; the chemist was dispatched
on test coverage. Restricted to objects inside the reviewer's own assigned domain, nothing flips —
all nine land on DISAGREE_EVIDENCE and stay there. The ambiguity is manufactured by offering a
reviewer a proposition from a different reviewer's remit, which is a thing this system's dispatch
never does.

So the sharper and smaller version of the claim: the crew's domain assignment already supplies a de
facto object, which is why the tags are usable at all here. What is missing is any place that states
it. A crew reviewer receives a diff and a domain, not a proposition, so nothing stops a later reader
— or a tagger — from resolving the tag against the wrong object, and nothing in the record would show
that it had happened. That is structural, not stylistic, and it is a smaller finding than an earlier
revision of this document claimed.

The three `docs` findings do not depend on any of this. Each contradicts a proposition the executor
actually wrote down — a count, a date argument, a median — so the object comes from the artifact
rather than from a choice. Having an object is not the same as having a tag that fits, though: one of
those three, finding 12, has an unambiguous object and still takes NO FIT below, for a reason that
has nothing to do with objects.

Tagging under Object B, which is the reading that preserves the finding text:

| #   | Finding, abridged                                                                                              | Tag               |
| --- | -------------------------------------------------------------------------------------------------------------- | ----------------- |
| 1   | no fixture covers wave 0 or negative wave numbers on the contiguity arm                                        | DISAGREE_EVIDENCE |
| 2   | `sort_by(.wave)` survives deletion; no fixture separates array order from wave order                           | DISAGREE_EVIDENCE |
| 3   | `depends` / `blocked_by` aliases never exercised by any fixture                                                | DISAGREE_EVIDENCE |
| 4   | one assertion survives a null-implementation stub                                                              | DISAGREE_EVIDENCE |
| 5   | arms 2, 3, 5 have no label-level green assertion, asymmetric with 4/6/7                                        | DISAGREE_EVIDENCE |
| 6   | doc says "17 false violations"; the real output is 1 arm carrying a count of 17                                | DISAGREE_EVIDENCE |
| 7   | edge-ordering arm checks only the first dependency; mutant survives 35 assertions — **"not a shipped defect"** | **NO FIT**        |
| 8   | the declared mutant is too blunt; the minimal one is what pins the counter                                     | DISAGREE_EVIDENCE |
| 9   | fallback dedup key unexercised and currently unreachable                                                       | DISAGREE_EVIDENCE |
| 10  | `agent==null` rollup arm has no dedicated fixture                                                              | DISAGREE_EVIDENCE |
| 11  | a mixed-era group would land in neither sub-bucket; 33+5=38 by coincidence                                     | DISAGREE_EVIDENCE |
| 12  | the threshold was fixed after the deciding evidence was read; an unregistered bucket flips the count           | **NO FIT**        |
| 13  | the reported median is itself an unflagged lower bound, truly `[23%,77%]`                                      | DISAGREE_EVIDENCE |

The four gate lines behave better than the findings do, and for the same reason: a wave verdict has an
object, namely the wave's work. Three map to AGREE — two `CLEAN` interims and the re-crew `CLEARED`.
The fourth, the A6 wave's `not clean, 0 gating`, maps to DISAGREE_EVIDENCE: its summary is
"measurement layer sound; census and pre-registration are not ... the doc overstates its own rigor".
The re-crew line is an AGREE that also carries finding 7, so the tag describes half of it.

### The two that fit nothing

**Finding 7 — "not a shipped defect."** The reviewer found a surviving mutant, cited the line range,
and then explicitly declined to call it a defect. That is an agreement with a reservation, and the
vocabulary has no cell for it: AGREE erases the mutant, DISAGREE_EVIDENCE erases the decline. The
decline is the load the sentence carries — it is what tells the orchestrator not to spend a corrective
on it.

**Finding 12 — the pre-registration objection.** By the-chemist's own gate line this is the most
valuable finding of that wave: the A6 doc's threshold "was fixed before the TALLY but after the
deciding evidence was already read", and an unregistered scoring bucket added at write-up time is what
flips the verdict from threshold-met to threshold-not-met. It is an epistemic objection to the
reliability of a document's own reasoning — DISAGREE_CONCERN's exact territory, whose payload the
paper spells `<epistemic objection>` — but it is backed by concrete citations and two counts.
DISAGREE_CONCERN understates it. DISAGREE_EVIDENCE miscategorizes it, and its payload is spelled
`<code citation>`, while findings 6, 12 and 13 cite a document, a timeline and a journal. The paper's
response protocol on DISAGREE_EVIDENCE is to "revise the flag based on the evidence, or drop it",
which is not the problem; the problem is that the evidence the tag is built to carry is code, and
none of these three is about code. (That finding was upheld and acted on: see
`docs/corrective-wave-rerun-findings.md` §"Correction: the threshold did less work here than the
framing claims".)

So on 13 real findings the three-tag set fits 9 once their object is taken from the reviewer's own
domain, fits 2 without strain, and fits 2 not at all. One of the last two is the finding the reviewer
itself rated highest, and it fails on payload rather than on object.

### What this system already has

E-5's premise is that free-text pushback is the status quo. It is not. `gates.jsonl` already carries a
three-token discrete finding field:

> `outcome: "batch"` is the refutation-posture reviewer's own way of saying the same thing — a
> defensible defect it can cite, below the floor. It exists because a binary `refute|promote` forces a
> reviewer to either block on a nit or stay silent about it, and the first is what produced four
> consecutive `refute` verdicts on a one-line CSS fix.
>
> — `skills/loop-de-looper/references/state-schemas.md`

`refute` / `batch` / `promote` is already three discrete tokens, already per-reviewer, already
un-aggregated. It maps onto AR's set almost cell for cell — `promote` ≈ AGREE, `refute` and `batch` ≈
DISAGREE_EVIDENCE at and below the gating floor. Each set has one dimension the other lacks: this
system's carries severity, AR's carries the evidence-versus-concern split. Exactly one of the 13
findings, number 12, is an instance where that split would have carried information the free text
lost.

The field's real problem is not its vocabulary. Across all 126 crew lines in the corpus — a live
count, since this run appends to it:

```
for f in $(find ~/Developer/Repos -path '*/local/loops/*' -name gates.jsonl); do
  jq -r 'select(.kind=="crew") | (.outcome//"NULL")' "$f"; done | sort | uniq -c | sort -rn
```

| Value                                            | Lines |
| ------------------------------------------------ | ----- |
| absent                                           | 80    |
| `refute`                                         | 11    |
| `promote`                                        | 11    |
| `batch`                                          | 11    |
| `fixed` — off schema                             | 8     |
| `CLEARED` — off schema                           | 1     |
| an entire free-text review pasted into the field | 4     |

33 of 126 carry a legal token; 13 carry an off-schema value, four of them prose runs of 315, 498, 557
and 573 characters. `grep -n 'outcome' scripts/loop-finding-audit.sh` prints nothing: unlike `kind`,
whose enum is enforced and whose enforcement exists precisely because one run logged 31 spellings
across ~50 lines, `outcome` is documented and unchecked. It drifted the same way and less far — nine
distinct non-null values across 126 lines, against that run's 31 across ~50 — for the same reason.
The denominators differ by more than a factor of two, so "less far" is about the count of spellings,
not a rate.

Adding a second three-token vocabulary beside an unenforced first one is not the intervention this
evidence supports.

### Cross-check, a different reviewer-run

To keep the result off one run's house style, the same retag was run over the-chemist's gate line on
carn `phase/1b` wave 9 — a different repo, a different run, a code defect rather than a document:

> refute: proven surviving mutant at src/git/spawn.ts:79-83 -- semaphore leak on abort-while-queued
> arm, same bug class as the already-fixed sync-throw leak, mutation-confirmed (deleting release()
> there leaves all 6 tests green)

This maps cleanly and without strain: DISAGREE_EVIDENCE, with a genuine code citation and an
executable proof behind it. Its `outcome` field is already `refute`. The clean mappings cluster where
the finding is a code defect with a line range and an executable proof; every finding that strains the
vocabulary — the two NO FITs, and findings 6 and 13 whose `<code citation>` is a document or a journal
— is about a document, a method, or a reviewer's own confidence. E-5 is a code-review proposal being
asked to carry review of prose.

## Flags

Two things were noticed and not acted on. Neither was caused by this wave.

- **`outcome` accepts anything.** Eight `fixed`, one `CLEARED` and four pasted reviews sit in a field
  the schema declares as three tokens, and `loop-finding-audit.sh` does not read the field at all.
  This is the same class as the `kind` enum drift that audit already guards, and it is the one
  concrete change this shadow test would support — enforce the field that exists rather than add
  another.
- **`.fixture` files cannot satisfy the zero-comment rule's proof.** Case 2 shows a tracked fixture
  carrying two real scan candidates that `doc-bloat-scan.sh` structurally cannot reach, by either
  entry path. Any wave that reports a clean scan on a `.fixture` file has reported that it did not
  look.
