# [Looper](../agents/the-looper.md) framework v1

The looper skills + agent compose into a multi-wave orchestrator named
[Loop de Looper](../skills/loop-de-looper/SKILL.md). Hand it a goal that spans
more than one loop and it runs a nonbeliever pre-flight, produces a wave
queue, dispatches `the-looper` per wave, schedules crew passes at trigger
points, emits a plain-language recap, and surfaces required-not-loopable
items to the user at termination.

Per-wave flow inside `the-looper`:

- `research → plan → build → verify → review → learn → commit`

Cross-wave flow inside Loop de Looper:

- `nonbeliever → scope → wave loop × N → final crew → recap → terminate`

The nonbeliever pre-flight challenges the goal + approach against CLAUDE.md,
existing agents, skills, and directives before any wave runs — advisory
unless it hits a hard rule conflict. The recap closes the run with a clean,
shareable summary drawn from the gate log + git history; it narrates, it
never decides.

Loop de Looper's operational safety rails – the budget governor,
usage-window guard, gate artifacts, and durable run-state – are specified
in its SKILL, `skills/loop-de-looper/SKILL.md`.

Plan absorbs the deterministic portion of pre-build specialist judgment so
the loop stays autonomous unless real residual judgment is needed. When
plan emits `ESCALATE: <gate>`, the agent stops; orchestrator invokes the
named specialist, appends its output as `gate outputs`, and re-dispatches.

## Config validation

The agent + skill specs are themselves checked. `scripts/validate-looper-config.sh`
asserts every `agents/*.md` and `skills/*/SKILL.md` has the frontmatter the
harness resolves on (`name`, `description`) and that the declared name matches
its path — a malformed name silently breaks resolution. It also warns on
backtick'd repo-relative path references that don't resolve (doc rot), while
leaving `[[memory-links]]` alone (a dangling one is a valid forward-reference).
The `.github/workflows/validate.yml` CI job runs it on every push and PR, so a
broken spec can't land; run it locally before committing spec edits.
