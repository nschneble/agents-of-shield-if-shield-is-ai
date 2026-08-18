# [Looper](../agents/the-looper.md) framework v1

The looper skills + agent compose into a multi-wave orchestrator named
[Loop de Looper](../skills/loop-de-looper/SKILL.md). Hand it a goal that spans
more than one loop and it runs a nonbeliever pre-flight, produces a wave
queue, dispatches `the-looper` per wave, schedules crew passes at trigger
points, emits a plain-language recap, and surfaces required-not-loopable
items to the user at termination.

Per-wave flow inside `the-looper`:

- `research → plan → build → verify → review → learn → commit`

Each of those steps is checkpointed to a per-wave journal under
`local/loops/<branch>/` as it completes, so a dispatch killed mid-wave
resumes at its next unfinished step rather than repeating the wave. The
contract lives with the executor, in `agents/the-looper.md`.

Cross-wave flow inside Loop de Looper:

- `nonbeliever → scope → wave loop × N → cleanup batch → final crew → recap → terminate`

The nonbeliever pre-flight challenges the goal + approach against CLAUDE.md,
existing agents, skills, and directives before any wave runs — advisory
unless it hits a hard rule conflict. The recap closes the run with a clean,
shareable summary drawn from the gate log + git history; it narrates, it
never decides.

## What holds a run to the ask

The failure mode a multi-wave loop drifts into is not shipping the wrong
code, it is shipping the right code and then not stopping. A crew of
seven reviewers will always find something; each finding is real, cited,
and defensible; and a protocol that treats "a reviewer called it a
blocker" as "this blocks" converts every one of them into a wave. Two
runs measured it: a one-line CSS fix that took four waves and three
correctives, and a twenty-wave run that spent ten correctives while one
of its two stated asks never got started.

Two rules answer that, both in `skills/loop-de-looper/SKILL.md`:

The **goal contract** is `looper-scope`'s section 0 — the user's asks in
their own words, each with the criterion that closes it. It is persisted
to `run-state.json`, carried verbatim into every wave brief and every
crew prompt, and fixed for the run. Work discovered later goes to the
user as a question, never into the contract.

The **severity floor** is what a finding must clear to block a wave: a
correctness regression in the run's own diff, a security defect, data
loss, an a11y regression on UI the run shipped, or a false user-visible
string — and it must cite a contract ask or a line the run changed.
Docs, naming, conventions, test hygiene, surviving mutants, refactor
opportunities, and voice are real findings that batch to one terminal
cleanup wave. Nothing is dropped; it is scheduled.

Each crew agent's own definition names which of its findings can gate,
so the rule is not only in the orchestrator's prose. And
`scripts/loop-finding-audit.sh` fails a run whose corrective waves
cannot be accounted for by justified gating findings — a prose rule the
orchestrator can out-narrate is what these two runs already disproved.

That audit checks accounting, not substance. It can tell that a
corrective named a gating class and cited something; it cannot tell
whether the class was chosen honestly or the citation points at real
code. What bounds a run that lies fluently is still the corrective
ceiling in the budget governor. The audit closes the gap between a rule
written down and a rule observed, which is the one these runs fell
through.

Loop de Looper's operational safety rails – the budget governor,
usage-window guard, gate artifacts, and durable run-state – are specified
in its SKILL, `skills/loop-de-looper/SKILL.md`.

Plan absorbs the deterministic portion of pre-build specialist judgment so
the loop stays autonomous unless real residual judgment is needed. When
plan emits `ESCALATE: <gate>`, the agent stops; orchestrator invokes the
named specialist, appends its output as `gate outputs`, and re-dispatches.

## Unexpected state is the owner's until proven otherwise

Every looper skill and agent works in repos the owner also works in
between runs, so state that does not match what a run expected is more
likely their deliberate act than an errant process. A PR that reads
differently, a file that moved, a commit no wave made, a memory that
contradicts another: assume authorship before assuming malfunction.

Surface it and say what you observed; do not revert, overwrite, or
restore. Where a merge is genuinely needed, augment additively, leaving
the owner's own content byte-identical. The `pr.body_sha` guard in
`skills/loop-de-looper/SKILL.md` (Step 4) is the worked example.

Acting anyway is allowed on a mechanically verified cause, never on an
inference: a baseline the run itself wrote and can diff against, or a
reproduced defect with a named mechanism. Two stray commits in this repo
fit a rogue process and a deliberate act equally well; what settled it was
reproducing an unguarded `mktemp -d` in the repo's own test suites
committing into the invoking repo. A plausible story does not clear the
bar, and external state is stricter still: a verified cause there routes
to the owner rather than licensing a self-correction.

## Config validation

The agent + skill specs are themselves checked. `scripts/validate-looper-config.sh`
carries four responsibilities, split across two severities.

Two ERROR. It asserts every `agents/*.md` and `skills/*/SKILL.md` has the
frontmatter the harness resolves on (`name`, `description`) and that the declared
name matches its path — a malformed name silently breaks resolution. And it
asserts every `*.test.sh` in the tree is actually invoked by
`.github/workflows/validate.yml`, reading only the command text CI executes
rather than any mention of the path: a suite CI never runs is a red nobody sees,
which `doc-bloat-scan.test.sh` demonstrated by sitting out of the workflow for a
week while failing. That check is why `scripts/validate-looper-config.test.sh`
exists — the wiring match has been wrong in both directions, and both were
silent.

Two WARN. Backtick'd repo-relative path references that don't resolve are doc
rot, reported without blocking a merge, while `[[memory-links]]` are left alone
(a dangling one is a valid forward-reference). And every `/<skill> <verb>` a
skill declares must appear in `docs/looper-skills.md`, so a skill can't grow a
subcommand while the doc that enumerates the family keeps the old shape — two
verbs had already drifted that way when the check landed.

The `.github/workflows/validate.yml` CI job runs it on every push and PR, so a
broken spec can't land; run it locally before committing spec edits.
