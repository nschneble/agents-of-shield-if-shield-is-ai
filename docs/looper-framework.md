# [Looper](agents/the-looper.md) framework

## v1

The looper skills + the-looper agent compose into a multi-wave orchestrator
named [Loop de Looper](skills/loop-de-looper/SKILL.md). Hand it a goal that
spans more than one loop ("finish the theme refactor", "harden auth
boundary", "flip draft PR to ready-for-review") and it produces a wave
queue, dispatches `the-looper` per wave, schedules crew passes at trigger
points, and surfaces required-not-loopable items to the user at
termination.

Per-wave flow inside `the-looper`: `research → plan → build → verify →
review → learn → commit`.

Cross-wave flow inside Loop de Looper: `scope → wave loop × N → final crew
→ terminate`.

Plan absorbs the deterministic portion of pre-build specialist judgment
(mechanized contract tests, Squawk dry-run, caller-graph grep, baseline
measurement) so the loop stays autonomous unless real residual judgment is
needed. When plan emits `ESCALATE: <gate>`, the agent stops; orchestrator
invokes the named specialist, appends its output as `gate outputs`, and
re-dispatches.

The framework shipped in five commits (v1.0–v1.3 + caveman compression),
each grounded in observed gaps from a real end-to-end exercise.
