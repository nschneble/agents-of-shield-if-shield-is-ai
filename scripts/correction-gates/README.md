# Correction gates — the corrections→gates compile step

A **registry** of recorded corrections that have been compiled into
executable checks, plus a **runner** that executes all of them as one
`looper-verify` step. This is the generalization the format-scope pilot
(E-greenlight-1, PR #41) unlocked (issue #40, E-greenlight-2).

## Why this exists

A correction stored only as prose in memory re-violates: recall is not
enforcement. The research this loop mined measured the gap directly — even
a strong memory system leaves most preference checks violated (C1), and
compiling corrections into runtime checks that must pass before completion
closes it (C2/C25). The novelty is **provenance**: a check comes from a
correction the loop actually received, not an author guessing ahead of time
(C3). This registry is where those compiled checks live and run.

The pilot proved it for ONE correction (format-scope). This step turns that
one-off into a substrate: any recorded correction can become an entry, and
the runner forecloses recurrence for every entry, not just the first.

## Layout

```
correction-gates/
  README.md                     this file — schema + compile procedure
  run-correction-gates.sh       the runner (discovers + runs all entries)
  run-correction-gates.test.sh  both-directions test for the runner
  <id>/                         one entry per compiled correction
    spec.md                     the check-spec (schema below)
    gate.sh                     the executable assertion
    gate.test.sh                its both-directions test
```

Each subdirectory holding a `spec.md` is one entry. Adding a correction is
dropping a directory — the runner discovers specs and never changes as the
registry grows.

## The check-spec schema (`spec.md`)

YAML frontmatter, then a prose body. The runner reads three top-level
scalar fields; the rest is provenance the human maintains and the reader
relies on.

| field        | read by runner | purpose                                                    |
| ------------ | :------------: | ---------------------------------------------------------- |
| `id`         |       yes      | stable identifier (also the directory name)                |
| `enabled`    |       yes      | `false` parks an entry without deleting it (runner SKIPs)  |
| `exec`       |       yes      | the command the runner runs, from the entry dir           |
| `title`      |        —       | one-line human summary                                      |
| `needs`      |        —       | which wave-context vars the exec consumes (documentation)  |
| `provenance` |        —       | where the correction came from: `memories`, `correction` (the atomic rule), `recurrence`, `origin`/`pilot` |
| `asserts`    |        —       | what the compiled check asserts, in one sentence           |

`exec` is run via `bash -c` from the entry directory, so it can reference
the wave-context variables the runner exports. Specs are repo-committed and
reviewed — the same trust posture as any in-tree script.

### Wave-context contract

The runner exports a fixed set of variables the `exec` lines read:

| variable          | meaning                                                     |
| ----------------- | ----------------------------------------------------------- |
| `CG_DIR`          | repo working root the wave built in (absolute)              |
| `CG_RANGE`        | git ref/range a gate compares against (default `HEAD`)      |
| `CG_TOUCHED_FILE` | wave's declared touched files, one per line (may be empty)  |
| `CG_CHANGED_FILE` | explicit changed-file list, one per line (may be empty)     |

A gate that needs none of these (a whole-tree scan) simply ignores them.

## The compile procedure (recorded correction → registered check)

Semi-manual and human-in-the-loop by design — a human decides a correction
is worth compiling and authors the check; the registry only makes the
result runnable and durable.

1. **Recorded correction.** Start from a correction that recurred — a
   memory that re-violated across waves, a repeated crew finding. Recurrence
   across independent branches is the signal it is worth a gate, not prose.
2. **Atomic rule.** Distill it to one falsifiable assertion: "X must hold"
   / "Y must never appear." If you cannot state it as one runnable check,
   it is a policy line, not a gate — leave it in memory.
3. **Check-spec.** Create `<id>/spec.md` with the frontmatter above.
   Provenance names the memory/correction it came from (the C3 property).
4. **Executable + test.** Write `<id>/gate.sh` (pure bash/jq/git/grep — no
   hosted tool) with exit codes `0` clean / `1` violation / `2` env-usage,
   and `<id>/gate.test.sh` proving it BOTH directions (RED on a violating
   fixture, green on a clean one).
5. **Register.** The runner already discovers the new directory. Wire the
   new test into `.github/workflows/validate.yml` so it cannot rot.
6. **Verify uses it.** `looper-verify` runs `run-correction-gates.sh` on a
   wave whose diff could re-trigger any registered correction; a violation
   is a first-class verify failure.

## Running

```sh
# all entries, against a wave's build:
./run-correction-gates.sh --dir <repo> --touched-from <touched.txt>

# exit: 0 all clean · 1 a gate found a violation · 2 a gate could not run
```

CI runs the both-directions TESTS (stub/fixture-driven, no prettier/node
needed), not the live runner over this repo — the live runner belongs in a
wave's verify step, in the target repo where the tools it calls exist.

## Registered entries

| id                  | class                          | provenance                        |
| ------------------- | ------------------------------ | --------------------------------- |
| `format-scope`      | file formatting (pre-commit)   | E-greenlight-1 pilot, PR #41      |
| `no-ai-attribution` | commit/PR-surface hygiene      | memory `no-ai-attribution`, PR #8 |
