---
name: loop-de-looper
description: Orchestrator for multi-wave goals. Trigger when the user says "loop de looper", "run all the waves", "autonomous loop", or hands a multi-wave goal expecting hands-off execution.
---

Parent orchestrator. Input = raw goal. Output = goal-complete or escalation. Composes existing pieces; no re-invent.

Loop de Looper NOT execute waves directly. Dispatches `the-looper` agent per wave; the-looper runs full wave protocol internally (research → plan → build → verify → review → learn). Crew passes scheduled at trigger points by `loop-de-looper` itself. Orchestrator = parent (entity invoking this skill), not separate agent.

## Why exists

User hands multi-wave goal ("finish theme refactor", "harden auth boundary"). Without orchestrator:

- Each wave needs manual queue management (which candidate next?)
- Each wave needs manual brief construction (which files, which contracts?)
- Crew passes skipped (drift accumulates silent) or run per-wave (slow, wasted parallelism)
- Termination ad-hoc (when goal done?)

Loop de Looper formalize protocol so parent runs goal → done without per-wave human intervention, preserve safety gates (specialist escalation, crew passes, stop conditions).

## Composition

```
loop-de-looper(goal)
├── looper-nonbeliever(goal, approach)        → interrogate + size goal; verdict PROCEED|NOTES|STOP + sizing inline|single-wave|full
│      ├── sizing inline       → skip scope + wave loop; do it inline, report (no queue, no crew)
│      ├── sizing single-wave  → one the-looper dispatch, skip queue + crew cadence
│      └── sizing full         → continue to scope (default multi-wave path)
├── looper-scope(goal[, notes])               → wave queue + exit criteria + required-not-loopable items
└── for each wave in queue:
    ├── the-looper agent(wave brief)          → runs research → plan → build → verify → review → learn → commit
    │      ├── wave 1: brief pr=create-on-wave-1, push=true → looper-commit pushes + opens draft PR
    │      ├── waves 2…N: brief pr=existing #N, push=true   → looper-commit commits into the PR
    │      └── if plan emits ESCALATE:        agent stops, hand-back has `gate needed pre-build`
    │            ├── orchestrator invokes specialist via Task tool
    │            ├── orchestrator appends `gate outputs` to brief
    │            └── re-dispatch the-looper (resumes at build, skips plan)
    ├── update counters (waves shipped, cumulative blast radius)
    └── if crew_trigger():
        └── crew pass(branch state)           → blocker / warning / nit findings; loop back if blockers
└── final crew pass(cumulative branch)        → before declaring goal-complete
└── PR finalization backstop                  → assert PR exists; create if a wave missed it
└── looper-learn(run mode)                     → diagnose the orchestration (sizing/scope/cadence); WRITE lessons before recap
└── looper-recap(run state)                    → plain-language closing summary (read-only) before terminate
└── report exit state to user (incl. PR #/URL)
```

`looper-nonbeliever`, `looper-scope`, `looper-plan` (invoked inside the-looper), `the-looper`, `looper-recap` already exist. Crew = seven agents (named with roles in `## Protocol` Step 3), invoked in parallel via Task tool per memory `[[the-crew-agent-group]]`.

## Inputs

1. **Goal**: raw user input. Single sentence to single paragraph.
2. **PR context (optional)**: existing PR number if updating draft. `gh pr view <N>` body becomes scope input.
3. **Resume flag (optional)**: `resume` to continue prior run. Reads `local/loops/<branch>/run-state.json` as authoritative (queue, counters, PR, last-crew); falls back to git-derive only if that snapshot is missing or corrupt. See `## State tracking`.

## Protocol

### Step 0: Nonbeliever pre-flight (once per run)

Invoke `looper-nonbeliever` via Skill tool. Pass goal + the orchestrator's intended approach (one paragraph: how it means to run this).

Nonbeliever interrogates goal + approach against `CLAUDE.md`, existing agents, existing skills, and active directives. Emits a verdict:

- **PROCEED** → continue to Step 1 unchanged.
- **PROCEED-WITH-NOTES** → carry the notes (drop a redundant wave, add a gate) into scope input at Step 1.
- **STOP** → hard contradiction (rule conflict, user-authority decision, required-gate substitution). Surface nonbeliever output to user; do NOT proceed to scope.

Nonbeliever is advisory by design: a challenge being _raised_ does not halt the run, only a STOP verdict does. Do NOT improvise around a STOP — same discipline as a scope refusal.

Nonbeliever also emits a **SIZING** label. On any non-STOP verdict, route on it BEFORE Step 1 — most goals handed here size `full-orchestration`, but a misfiled small ask should not pay full freight:

- **inline** → the goal does not warrant the loop. Skip scope AND the wave loop entirely; make the change inline (or hand back "do this inline"), then go straight to the exit report. No queue, no crew, no recap — there is no multi-wave run to summarize.
- **single-wave** → dispatch `the-looper` once with a single-wave brief (scope + `target` + PR directives: `pr: create-on-wave-1`, `target.push: true`); the-looper runs its own research → plan → build → verify → review → learn → commit internally. Skip the scope queue and the crew cadence; still run the PR-finalization backstop (Step 4) so the one commit lands on a PR.
- **full-orchestration** → proceed to Step 1 (scope) as normal. This is the default and the common case.

A STOP halts regardless of sizing. Sizing never overrides a STOP, and it never shrinks a vague goal — nonbeliever sizes unspecified work as STOP, not `inline`.

### Step 1: Scope (once per run)

Invoke `looper-scope` via Skill tool. Pass goal + PR context (+ nonbeliever notes if PROCEED-WITH-NOTES).

Scope produces 8-section output. Loop de Looper validates:

- Goal restatement matches user intent (orchestrator surface to user if drift suspected)
- Classification non-REFUSE (open-ended goals → scope refuses → Loop de Looper stops)
- Wave queue non-empty (empty queue → goal already met → report + stop)
- `Required, not loopable` items captured (surface to user at end, never silent skip)
- **Executor-writability pre-flight.** Before queueing waves that write a given directory, confirm `the-looper` (a SUBAGENT) can actually write there. Some projects gate subagent writes to UI dirs (e.g. a `.tsx`/`components/` write-gate or a permission allowlist) — invisible to a main-agent check, since the gate is subagent-scoped. A queue full of waves the executor cannot write turns every wave into an unclearable escalation (the specialist that would "clear" it has no Write tool either — see Step 2b). Probe once (or read project memory for a known gate); if the executor is gated out of the target dir, surface to the user BEFORE burning a pilot dispatch, and consider a non-gated target or a main-agent-build fallback.

  **A session-marker gate false-negatives on a COLD probe — probe AFTER its clearing action, not before.** Some UI write-gates are PreToolUse hooks that DENY until a session marker exists, dropped the first time a clearing specialist runs (e.g. `accessibility-agents`' `a11y-enforce-edit.sh` denies `.tsx`/`components/` writes until `/tmp/a11y-reviewed-<SESSION_ID>` exists, set by a PostToolUse hook when `accessibility-lead` runs once; subagents share the parent SESSION_ID, so the orchestrator's per-wave a11y-lead brief clears it session-wide). A probe in a virgin session — before any a11y-lead consult — ALWAYS blocks; reading that as "executor can't write here" is a false negative that escalates a non-existent blocker (observed: a full round-trip on the theme-editor run). For a marker-scoped gate: run the clearing specialist (or set the marker) FIRST, THEN probe — and since the per-wave a11y-lead brief sets the marker anyway, a UI run whose waves each carry a pre-build a11y-lead gate needs no separate executor escalation. Only escalate when the gate has NO clearing action the orchestrator can trigger.

Scope stop conditions fire → Loop de Looper stops. Do NOT improvise around scope refusal.

**Exception: a goal that arrives as an already-vetted, user-approved implementation plan may skip `looper-scope`'s decomposition, but not its validation.** When the goal handed to loop-de-looper is not a raw ask but the output of a prior Plan-Mode cycle (research → plan agent → `AskUserQuestion` rounds → user `ExitPlanMode` approval), that cycle already performed scope's decomposition job — often with more rigor, since it verified load-bearing claims against the actual source and resolved open design decisions with the user directly. Re-running `looper-scope` on a terser restatement of an already-decided goal risks it inventing a DIFFERENT decomposition that silently overrides decisions the user already approved — an authority violation in the opposite direction from the one scope guards against. In this case the orchestrator may build the wave queue directly from the plan's own wave breakdown instead of invoking `looper-scope`, but MUST still perform scope's three mechanical validation checks by hand: wave queue non-empty, executor-writability pre-flight, and `required-not-loopable` capture (any inherent verification gap the plan's own research surfaced, e.g. "this class of change can't be exercised by the project's own CI"). Record the substitution and which checks were kept in `run-state.json` under `nonbeliever.notes` so a resume or audit can see the queue's real provenance. This is narrow: it applies only to a plan that went through real user back-and-forth, not to a self-authored plan the orchestrator wrote in the same turn without a check-in — that case still goes through `looper-scope` as normal.

### Step 2: Per-wave loop

For each wave in queue, in order:

#### 2a. Dispatch the-looper

**Stale-candidate pre-check (cheap, before the dispatch).** Scope builds the queue ONCE up front; by a later wave an earlier wave may have already renamed, deleted, or fixed what this wave targets. A full `the-looper` dispatch is expensive — don't spend one to hand back "file gone." Before dispatching, run a cheap glob/grep (a lightweight filter ahead of the costly call, ComPilot's two-stage check): do the target files still exist, and still exhibit the thing this wave addresses? Stale → mark the queue item `status: "skipped-stale"` with the reason, log it (`gates.jsonl`, `kind: "stale-skip"`), advance. Do NOT escalate — a stale candidate is already-handled work, not a blocker. Skip only when the target is provably gone or already-satisfied, NOT when a path merely moved (a moved target is a re-point, still a live wave). A stale-skip is NOT a no-progress event — no `the-looper` ran, so it never touches `consecutive_no_progress`; benign queue hygiene, not thrash.

Invoke `the-looper` agent via Task tool. Pass wave brief from scope's queue + project target (branch name, PR number).

`the-looper` runs full protocol internally: research → plan → build → verify → review → learn → commit. Returns hand-back report (`shipped`, `deferred`, `gate needed pre-build`, `gates needed post-build`, `ranked alternates`, `learn`, `flags`).

**Brief authoring — PR + push directives.** Every wave brief carries two SEPARATE flags; never bundle them into one "No PR, nothing flipped to ready" phrase — that conflation collapses two different actions and orphaned PR creation in a real run (`## PR lifecycle + push ownership`).

- `pr:` — `create-on-wave-1` (default on a fresh multi-wave branch) | `existing #N` (every wave once the PR exists) | `skip` (explicit, rare — throwaway spike). "Don't flip to ready-for-review" is NOT a `pr:` value; the draft is still created.
- `target.push: true` — on EVERY wave of an orchestrated run; the orchestrator owns push timing and its default-off is for standalone use, so it must set this explicitly (`## PR lifecycle + push ownership`).

**Brief authoring — four standing quality instructions that pre-empt the most common corrective wave.** Code built to a cleared pre-build contract ships _correct_ on the first build; the corrective waves that still fire are overwhelmingly **untested-invariant**, **stale-docstring**, **orphaned-prose**, and **unverified-duplicate-contract** gaps a crew catches after the fact — all cheaper to prevent in the originating wave than to close with a doc/test-only corrective wave plus re-crew. So every wave brief that ships runtime code carries these standing lines (the third fires only on deletion/removal waves, the fourth only on doc/example waves). Include `templates/wave-brief-standing.md` verbatim in every runtime-code wave brief — it carries the four instructions with their full observed-incident rationale.

These are prevention, not new scope — they cover the wave's OWN change (and, for a deletion, the references its own removal orphaned), same as the "delete dead code your change orphans" carve-out. A tightly-scoped "implement the contract, nothing beyond" brief is what suppresses them, so the brief must name them explicitly as in-scope.

**Gate authoring on a deletion wave — point the specialist at the CONSUMERS, not just the deletion site.** A pre-build gate (2b) whose brief names only the deleted/edited files gives the specialist no line of sight to a regression _outside_ that set. On a feature-removal wave the gate brief must additionally name the deleted feature's consumers, callers, and adjacent user-facing copy. Observed: an a11y-lead gate cleared the Try-It deletion cleanly but the WelcomePanel content regression (stale "hit Send" instructions) escaped it — WelcomePanel sat outside the gate's fileset, so the interim crew caught it a round later. Listing "…and every consumer/adjacent panel that referenced this feature" closes that blind spot up front.

**Brief authoring on an EXTRACTION / SPLIT / god-file-refactor wave — make the per-OUTPUT-file ceiling this wave's acceptance criterion, and demand the counts.** The no-god-files rule already binds the executor (`looper-build`) and the crew (`the-improver`, `the-stickler`), so bloat that merely relocates is a compliance gap, not a missing rule — restating the rule a sixth time fixes nothing. What the brief adds is scope and evidence: the ceiling applies to EVERY resulting file (not just the one being shrunk), and the executor must state each output file's code-LOC count in its hand-back. That reported count is the part nothing else asks for; without it the size signal silently re-trips on the NEW file — invisible to type-check and tests — and surfaces only at crew, costing a corrective split plus a re-crew. Take the threshold from the target repo's CLAUDE.md exactly as `looper-build` does; do NOT hardcode a number, or the brief will outrank the executor's own rule on a repo that sets a different bar. Observed: a wave thinned a 229-line hook to 70 but created a 138-code-LOC extracted module; the final crew flagged it as a BLOCKER and a corrective wave re-split it into three files under the bar.

#### 2b. Handle escalation (if any)

If hand-back contains `gate needed pre-build`, FIRST classify the gate — they are not all the same kind:

- **Design gate** (a judgment a specialist supplies: palette/contrast values, threat model, ARIA contract). A specialist CLEARS it by producing the missing judgment. Route to the named specialist below.
- **Tooling gate** (a write-block / permission denial / missing credential the executor hit). A specialist CANNOT clear it — the review crew (`the-diamantaire`, `the-stickler`) run `Bash, Read` only and `accessibility-lead` is likewise read/review-scoped: **no Write tool** among them, so invoking one to "clear" a write-gate accomplishes nothing. A tooling gate is a USER decision (exempt the executor, change the target, or accept a main-agent-build fallback). Escalate to the user immediately; do NOT round-trip a specialist that can't resolve it. Log the gate `ran: false` with the tooling reason.

For a design gate:

1. Invoke named specialist (e.g. `accessibility-agents:accessibility-lead`) via Task tool with input the-looper specified
2. Append specialist output to brief as `gate outputs`
3. Re-dispatch the-looper with updated brief. the-looper sees `gate outputs` populated, skips plan, resumes at build.

Record each pre-build specialist gate in the wave's gate artifact (see `## Gate artifacts`): which specialist, ran-vs-unavailable, verdict. A specialist gate the-looper _requested_ but the orchestrator could not actually invoke (no Task tool) must be logged as `available: false` — never recorded as passed.

Repeat 2b only until escalation cleared. Same specialist gate requested twice for same wave → STOP, escalate to user (palette / architecture decision needed beyond specialist resolve).

**Pre-mandated gates fire up-front, not via a round-trip.** Two sources tag a wave for an up-front gate: `looper-scope` (explicit queue tag) and the **UI-glob detector** the orchestrator runs over each wave's candidate files before dispatch. The UI-glob mirrors `looper-plan`'s `### UI-touching waves always tag` exactly (`*.tsx`/`*.jsx`/`*.vue`/`*.svelte`/`*.html`, server templates `*.leaf`/`*.ejs`/`*.erb`/`*.hbs`/Jinja, styling `*.css`/`*.scss`/Tailwind/token files) — any match makes the wave UI-touching and mandates `accessibility-lead`. Detecting it at dispatch time matters because the accessibility hook fires only on the parent prompt, never inside the executor subagent — the orchestrator is the only actor that can guarantee the gate. When tagged (by scope OR the UI-glob), invoke the specialist BEFORE dispatching `the-looper` and ship the contract as `gate outputs` in the first brief, so the wave skips plan and builds directly. Do NOT dispatch only to have the plan re-discover the known gate and hand back `gate needed pre-build` — that burns a dispatch to surface what scope already declared; the reactive 2b path is for gates the plan finds that scope did NOT foresee. If the specialist returns open design decisions that are implementation specifics inside the user's already-stated design (clip strategy, control reuse, caption copy), resolve them on the specialist's recommended defaults — not user-authority scope changes. A decision that re-opens scope (changes what the feature does) still goes to the user.

**Behavior-neutral corrective waves are the one carve-out to the up-front a11y gate — confirm post-build instead.** A crew-driven cleanup wave whose ENTIRE diff is provably non-behavioral (dead-code removal, comment fixes, an unreachable-predicate alignment leaving rendered output byte-identical) adds no new UI behavior or a11y surface — the live behavior was already gated when it shipped. Skip the up-front gate; instead re-run `the-auditor` on the corrective diff POST-build to confirm byte-identical rendered a11y output (the normal scoped-re-crew "domain the fix touched" path). Holds ONLY when the wave proves byte-identical output (tests green AND the diff changes no rendered attribute, role, name, or computed style). The moment a "cleanup" wave touches real markup/behavior it is a normal UI wave and the up-front gate is mandatory again (observed working: a post-crew cleanup wave skipped the gate, post-build the-auditor confirmed 0 a11y deltas). Do NOT stretch to a wave that "mostly" doesn't change behavior — "mostly" is a normal UI wave.

Other stop conditions from the-looper (verify fails twice, review verdict `rethink`, etc) do NOT bubble straight up — a _retryable_ one earns ONE from-scratch retry first (see 2b-retry). Do NOT swallow either way: a retry that fails again bubbles up unchanged.

#### 2b-retry. Stuck-wave retry-from-scratch (one shot, bounded)

Before bubbling a **retryable** the-looper stop up to Step 4, attempt EXACTLY ONE fresh-context re-dispatch — the "restart to escape a local optimum" move: a stuck agent escapes more often from a clean restart than from more turns on a rotted context (ComPilot's multi-run finding). "From scratch" means fresh CONTEXT — a clean re-dispatch dropping the rotted transcript — NOT a freshly-improvised plan (mechanic 2: revert to the next ranked alternate, improvise only when none exists).

**Resume is not retry — classify before you re-dispatch.** A wave that died with NO hand-back (session limit, crash, a killed session) did not fail; it was interrupted. That is a RESUME: re-dispatch it plainly and `the-looper` picks up at its next unfinished journaled step (`## State tracking`). Only a wave that handed back a retryable STOP below is a RETRY, and a retry never resumes — its brief's `prior attempt failed:` note is also what tells the executor to open a fresh journal segment instead of continuing the dead one (`agents/the-looper.md` `## Step journal`, which is also where the executor opens one unprompted — only when a torn declaration has voided the journal's authority). Do NOT spend a retry, or its `wave_retries` count, on an interruption.

**Retryable** (non-deterministic — a fresh attempt can plausibly differ):

- `verify fails twice` on the same root cause
- review verdict `rethink`
- a wave that tripped `consecutive_no_progress` (shipped nothing / re-opened the same blocker)

**NOT retryable** (deterministic — a retry hits the same wall and burns a dispatch): tooling gate / write-block / permission denial (2b above), nonbeliever STOP, scope refusal, a budget governor rail, or a design `gate needed pre-build` (that is the 2b specialist path, not a retry). These bubble up immediately.

Mechanics:

1. **Fresh agent, not a resume.** Re-dispatch `the-looper` with NEW context — drop the rotted context and failed path. A resume re-feeds the dead end and reproduces the failure.
2. **Directed, not blind — revert to the next ranked plan first.** The retry brief carries a `prior attempt failed:` note (the failure mode in one line, e.g. "verify failed twice on null-deref in `X`; prior approach tiled via `Y`"). The retry FIRST reverts to the next-highest-ranked alternate the wave's `looper-plan` emitted (`## Ranked alternate plans`, surfaced in the stuck hand-back), if one exists — vetted against the same constraints, exit criteria, and mechanized predictions while research context was fresh, so the shot is spent on a pre-vetted approach, not a cold guess (MapCoder, ACL 2024: revert to the next-highest-confidence plan rather than re-run the failed one). Only when the plan emitted NO ranked alternate does the retry improvise a DIFFERENT strategy from the failure signal. Either way pass the `prior attempt failed:` note — restarting with zero memory of why the last attempt died wastes the retry.
3. **One shot.** Best-of-2, no more. A second stuck hand-back on the SAME wave bubbles to Step 4 and escalates to the user.
4. **Log it.** Append a `kind: "wave-retry"` event to `gates.jsonl` (wave, original failure mode, retry outcome) — auditable like any gate. A retry that the orchestrator could not actually dispatch (no Task tool) logs `ran: false`, same discipline as `## Gate artifacts`.
5. **Counters.** A retry dispatch increments `total_waves` and `wave_retries` (never reset — budget input). It does NOT increment `corrective_waves` (those are crew-blocker fixes, a different cause). A retry that ships net-new work resets `consecutive_no_progress`; a retry that fails again counts toward it.

#### 2b-flags. Triage cross-file flags before advancing

A wave can SHIP clean yet hand back a `flag` naming a **cross-file incompleteness** — a reference (to a field, section, contract, channel in ANOTHER file) that doesn't exist yet, or a sibling file needing a matching change. Do NOT let it ride to the crew. "X references Y, but Y isn't defined" is a known defect the moment reported; deferring converts a one-line fix into a crew BLOCKER plus corrective wave plus re-crew (observed: a ranked-alternates hand-back field referenced by three files, defined in none, rode to the final crew at exactly that cost).

On every shipped wave, read the hand-back `flags` before dispatching the next:

- **Cross-file incompleteness** (a dangling reference the wave created) → action NOW: if a later queued wave touches the named file, fold the fix into its brief; otherwise spawn an immediate corrective wave. Resolved before the crew sees it.
- **Self-caused behavior-neutral debris** (dead code the wave's OWN change orphaned — an overridden CSS rule, an unused param after a deleted caller — that NO later wave touches) → clean it INSIDE the creating wave, do NOT flag-and-defer. Pre-authorize `the-looper` in the brief to delete debris its own change orphans (it already names that debris in its hand-back). Deferring is false economy: the-improver flags dead code regardless of later waves, and a crew-surfaced warning guarantees a corrective wave PLUS re-crew — a one-line in-wave deletion becomes a full round-trip (observed: a dead `.summary-item .label` rule + unused `apply()` param, both named in Wave 1's hand-back, rode to the final crew). A tight "implement the contract, nothing beyond" brief is what produced the flag-and-defer, so the brief must explicitly carve out "AND delete any dead code your change orphans" as in-scope, distinct from the no-scope-creep rule.
- **Out-of-scope observation** (a pre-existing issue the wave noticed but didn't cause) → capture for a future scope run; do not action mid-run.

Test is causation + reachability: did THIS wave create the dangling reference (or orphan the dead code), and can a queued/cheap wave — or the creating wave itself — close it? Yes → triage now. A flag about something the run never touched is not this case.

#### 2c. Update counters

Maintain run state (persisted — see `## State tracking`):

| Counter                    | Updated when                                                                                                    |
| -------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `waves_shipped`            | wave commit succeeds                                                                                            |
| `waves_since_crew`         | every wave; reset on crew pass                                                                                  |
| `cumulative_files_changed` | sum of `files changed` from `git diff --stat` for shipped waves; reset on crew pass                             |
| `last_review_verdict`      | from the-looper's review step                                                                                   |
| `total_waves`              | every wave dispatched, queue + corrective (never reset) — budget governor input                                 |
| `corrective_waves`         | every crew-blocker fix wave (not a queue item); never reset — budget governor input                             |
| `consecutive_no_progress`  | +1 on a wave that shipped nothing / re-opened the same blocker; reset on any wave that ships net-new queue work |
| `wave_retries`             | +1 on each stuck-wave from-scratch retry dispatch (2b-retry); never reset — budget governor input               |
| `scaffolding_only_correctives` | +1 on a corrective wave whose commit touches no product file (`git show --stat` lists only `*.test.*`, `*.spec.*`, test helpers, tsconfig); reset on any wave that touches one — budget governor input |

After updating counters, write `run-state.json` (atomic, see `## State tracking`), THEN evaluate the budget governor (`## Budget governor`), THEN the usage-window guard (`## Usage-window guard`), THEN the crew trigger. Order matters: persist before you might STOP or PAUSE, so a governor halt or a usage pause still leaves a resumable snapshot.

#### 2d. Crew trigger check

After every wave, evaluate trigger:

- `waves_since_crew >= 4` OR
- `cumulative_files_changed >= 30` OR
- `last_review_verdict == warning-saturated` (multiple consecutive warnings across waves) OR
- **the wave was novel/large/high-risk OR left debris** — crew NOW, regardless of the count/file floor.

Trigger fires → invoke crew (step 3). Threshold tunable per project via CLAUDE.md override; defaults above.

The first three are _drift_ signals (small changes accumulating unreviewed). The fourth is a _concentrated-risk / debris_ signal and is the one orchestrators most often under-apply (observed twice on theme-editor runs — see memory `[[feedback-loop-crew-cadence-risk-weighted]]`). Two sub-cases, both fire it:

- **Concentrated risk**: a wave shipped a new algorithm/generator, a state machine, a model inversion, or a single large diff. Crew it the moment it lands so a structural flaw surfaces small, not buried under later waves in a giant final-crew diff.
- **Debris**: a wave performed **deletions / removed a subsystem / left dead code or doc drift** — even when later waves do NOT build on it. The trap is reasoning "later waves don't touch this, so it can wait": deletion debris (an orphaned dead branch, a docstring/comment the deletion silently falsified) is flagged by a crew pass _regardless_ of whether later waves compound it, and deferring only concentrates the blocker + its corrective churn at the end. A wave that deletes a subsystem is a crew-now wave.

### Step 3: Crew pass (interim OR final)

Invoke seven crew agents in parallel via Task tool (one Task call per agent, same message):

- `the-auditor`: a11y audit on cumulative diff
- `the-chemist`: test coverage on cumulative diff
- `the-chronicler`: doc drift on cumulative diff
- `the-diamantaire`: expert correctness review
- `the-ghostwriter`: voice pass on prose surfaces in the cumulative diff (UI copy, comments, docs, commit subjects); findings only in crew mode, no edits
- `the-improver`: refactor opportunities
- `the-stickler`: convention conformance

**Every crew-agent prompt must explicitly state "report findings only, do not edit any files" — not just `the-ghostwriter`'s.** Several crew agent definitions are dual-purpose (their own system prompt says "audit or fix", "refactor and clean up") because they're also invoked standalone outside a crew pass. Inside a crew pass they must stay read-only — a crew member that edits the working tree bypasses the wave/commit/verify discipline entirely (no test run, no `the-looper` review, nothing in `gates.jsonl` beyond a verdict line). Observed: `the-chronicler`, prompted only to "review... report... with file:line," made a direct uncommitted edit instead of just reporting. The orchestrator caught it by chance via a routine `git status` check, not because the protocol required one. Two guardrails: (1) every crew prompt this run gets the explicit no-edit line, not just the one agent whose brief already had it; (2) run `git status --porcelain` immediately after every crew pass returns (interim or final) — a non-empty result means a crew member edited files directly, and that pending diff must be routed through a proper `the-looper` micro-wave (verify + commit) before proceeding, never committed directly by the orchestrator and never silently left uncommitted.

Each agent gets the cumulative diff since the last crew pass (or, for the final crew, since the run's own first wave commit). Scope to THIS run's commits, NOT blindly `main..HEAD`: a branch handed over mid-flight already carries unrelated pre-run work that would drown the crew in out-of-scope findings. Derive the base as the parent of wave 1's commit (`git diff <wave1>^..HEAD`); only a branch forked fresh for this run makes that equal `main..HEAD`. Findings categorized:

- **Blocker**: must fix before continuing (interim) or before goal-complete (final)
- **Warning**: should fix; track count for warning-saturation trigger
- **Nit**: capture for future scope run; no loop back

Blockers found → loop back: produce mini-brief for blocker fixes, invoke `the-looper` for one corrective wave, re-run crew on fix. No "ship anyway" path.

**A Warning-driven corrective wave (no Blocker) still needs a targeted, independent re-check before the queue advances — don't wait for the next crew pass to discover a false-fix claim.** The mandatory re-crew above only triggers on a Blocker. But a corrective wave fixing pure Warnings can itself ship a false "fixed" claim the orchestrator has no obligation to catch until crew runs again — and if that next crew pass is the FINAL one, or doesn't happen at all (a Warning-only fix on the last wave of a run), the false claim ships. Observed: a corrective wave reported "`npm run format` clean" as proof it fixed a Warning (`index.css` failing `prettier --check`), but the project's `format` script glob never covered `.css` — the command silently no-oped and exited 0. The orchestrator advanced to the next wave trusting the narrative; only the FINAL crew pass re-running the same specialist happened to catch it, correctly reclassified as a Blocker. For any Warning-fix claim that rests on a mechanically-checkable command (format/lint/build exit code, a specific file's lint-clean status), have the orchestrator re-run that EXACT check independently (e.g. `npx prettier --check <file>`, not just trust `npm run format`'s exit code) before dispatching the next queued wave — cheap, and it closes the gap a full re-crew would otherwise be the only thing to catch.

Re-crew scope follows the corrective diff, not ceremony. Re-run the agents whose findings the fix targeted (to confirm CLEARED), plus any whose domain the corrective diff actually touched. An agent that was clean AND whose domain the fix never entered need not re-run — e.g. a docs+test corrective wave that only deletes a dead attribute doesn't re-summon the correctness/a11y reviewers, provided the byte-identical/behavior-unchanged claim is verified. State which agents you re-ran and why; do NOT silently drop a clean agent whose domain the fix DID touch.

After every crew pass, write the gate artifact BEFORE looping back or resetting counters — which agents ran, Task availability, each verdict (`## Gate artifacts`).

The crew summary in any report (interim or final) enumerates ALL SEVEN agents by name with each verdict — even when clean. Listing only the agents that found something silently drops the rest; a reader can't tell "ran, clean" from "never ran" (the-improver was dropped from a clean report once exactly this way). A clean agent is reported as clean, not omitted.

Reset counters after crew pass clean.

### Step 4: Termination

Loop terminates when:

1. **All wave queue items shipped** AND **final crew pass clean** AND **section 5 empty** → goal-complete success path
2. **Stop condition fired** at any layer → escalate to user with state report
3. **All wave queue items shipped** AND **final crew pass clean** AND **section 5 non-empty** → cannot self-complete; surface to user with explicit list

**PR finalization (backstop — run on every path before declaring goal-complete or surfacing the report):**

1. Detect the run's PR: `gh pr list --head <branch> --state all --json number,url,state`. Persist `number`/`url`/`state` to `run-state.json`, and if `pr.body_sha` is unset, stamp it from the current body — the wave-1 executor writes that body inside its own dispatch, so the orchestrator stamps on first sight rather than expecting it in a hand-back.
2. No open/draft PR but committed work exists on the branch → backstop: ensure the branch is pushed (`git push -u origin <branch>`), then create the draft now (`looper-commit` Step 3). The Wave-1 model should already have created it; this catches the run where it didn't. NEVER declare goal-complete with committed work and no PR — that orphans the whole run off-dashboard. **Exception: a CLOSED PR is not a missing one.** Step 1's `--state all` surfaces it, and closing a PR is a user act (item 4) — do NOT open a replacement, which would restate work the owner just dismissed. Surface the closed PR and stop; the "no PR" backstop is for the run that never created one.
3. Report the PR #, URL, and draft/ready state in the final state report. "Branch is not a PR" is not an acceptable terminal state for shipped work. Flipping draft → ready stays the user's call (`looper-commit` spec) — creating the draft does not.
4. **A PR state the loop did NOT itself set is a USER edit — surface it, never revert it.** The loop's own components never flip draft→ready (`looper-commit` `## What looper-commit does NOT do`), so a PR found ready at finalization was not the loop: leave it, and do NOT `gh pr ready --undo`. Same for a closed PR (item 2's exception). The comparison is against `run-state.json`'s `pr.state`, the value the loop last wrote — any mismatch is the owner's. Observed: a run found #105 flipped-to-ready and body-rewritten by the user, un-readied it AND overwrote the body. A genuine tool bug goes to the user to decide; the loop does not self-correct external state.

**Run-level learn (run on success paths, after PR finalization, BEFORE recap):**

Invoke `looper-learn` via Skill tool in **run mode** (its `## Run-level diagnosis`). Pass the run trail: `gates.jsonl`, `git log --oneline main..HEAD`, the scope queue, the nonbeliever verdict + sizing. Learn diagnoses the ORCHESTRATION — sizing, queue hold, crew cadence, escalation thrash — and writes any lesson to its proper layer. Only step that learns about the _looping itself_; per-wave learn can't see past its own wave.

Learn runs BEFORE recap because learn WRITES (skill/agent/memory edits) and recap is READ-ONLY. Recap may cite a learn outcome as a fact, never invented. Skip run-level learn on the STOP/escalation path — a halted run diagnoses live in the escalation report instead.

**Recap (run on success paths, after final crew + PR finalization + run-level learn, before the exit report):**

Invoke `looper-recap` via Skill tool. Pass run state (`gates.jsonl`, `git log main..HEAD`, scope section 5, PR #/URL/state). Recap emits a plain-language closing summary, read-only — layers ON TOP of the structured exit report, not instead of it. Facts come from the same on-disk sources, so a gate logged `ran: false` stays `ran: false`. Skip recap on the STOP/escalation path.

**Structured-recap PR-body refresh (run on success paths, after PR finalization + recap, before the exit report):**

Refresh the PR body ONCE, at termination, with the structured recap (`looper-commit`'s `## Structured recap (PR-body section)` defines the FORMAT — file-tree, collapsed `<details>` diff hunks, UI wireframe; this step decides WHEN it fires). The body was created early at wave 1 before the whole-run diff existed, so the rich recap lands as a terminal `gh pr edit <N> --body` refresh — an external-state edit that changes the PR, not the branch.

- **User-edit guard (check FIRST, before composing anything).** The body may have been edited by the USER since the loop wrote it at wave 1. The baseline is `run-state.json`'s `pr.body_sha` (`references/state-schemas.md`), stamped after every write the loop itself makes to the body. Before refreshing: read the live body (`gh pr view <N> --json body --jq .body`), hash it, compare. Match → still the loop's own text, refresh normally. Differ, or `body_sha` absent → treat as user-edited. Do NOT replace it with a generated recap; two allowed moves only: (a) leave it entirely, or (b) AUGMENT it additively — append genuinely-new items into the sections the user already wrote (e.g. drop a real fix into their `**Fixed:**` list), leaving every line they authored byte-identical, matching their structure. The distinction is augment vs overwrite, never touch vs don't-touch. A wholesale `gh pr edit --body` that discards the user's version is the failure this guard exists to stop (observed: a terminal refresh clobbered a user-rewritten body). Re-stamp `pr.body_sha` from whatever you end up writing.
- **Recovering a body an earlier refresh already clobbered.** The edit history is readable: `repository.pullRequest.userContentEdits(first:N){nodes{editedAt editor{login} diff}}`. Each node's `diff` is that revision's FULL body text, not a patch — GitHub's schema calls it "a summary of the changes," which is wrong. The connection is **newest-first**, so `nodes[0]` is the CURRENT body: on a clobbered PR that IS the clobber, and restoring it re-applies the damage. The user's text is the next node down. Walk outward from `nodes[1]` for the newest revision that isn't the loop's; `diff` is nullable on older/deleted revisions, so skip null nodes instead of reading one as an empty body. `editor.login` cannot discriminate — the loop authenticates as `@me`, so its edits carry the owner's login too; go by timeline position, never by author. Best-effort: if no node holds the user's version, say so in the report and leave the live body alone.
- **Source diff.** Build every block from the WHOLE-RUN diff — the SAME base the final crew derives (`git diff <wave1>^..HEAD`, Step 3). Reuse it; do NOT reinvent a base.
- **UI-glob gate.** Reuse the EXISTING UI-glob detector (`## Protocol` 2b pre-mandated). Matched → INCLUDE the before/after wireframe + a11y call-out; no match → omit.
- **Small-diff skip.** Honor `looper-commit`'s small-diff skip — a genuinely tiny run gets NO refresh; the raw diff reviews faster.
- **Brevity + voice.** Assemble the body per `looper-commit`'s PR-body guidelines (lean sections, no diff restatement, no AI-attribution trailer), then run it through `the-ghostwriter` (sentence case, no em-dash, no slop) BEFORE the `gh pr edit`. This terminal refresh is the run's one pass at the whole-run body; make it read right. **On the augment path the ghostwriter sees only the lines you ADD** — the user's own prose ships byte-identical however it reads, since a voice pass over it is exactly the overwrite the guard above forbids.
- **Best-effort, never a gate.** A failed refresh (API error, body too long) LOGS and continues to goal-complete; the backstop above owns the PR's existence, the recap only enriches it.
- **Skip on the STOP/escalation path** — same discipline as recap and run-level learn.

For path 3 (release-readiness goals typically), order fixed:

1. Run final crew pass FIRST (against cumulative loopable work)
2. Then report to user with bundle:
   - Loopable waves shipped (list)
   - Final crew result (pass / pass-with-nits / blockers)
   - Required-not-loopable items still blocking (list from scope section 5)
   - Recommended user actions (each line)

Final crew runs before surfacing required-not-loopable so user gets verified loopable work + open human gates in one report, not two round-trips.

User executes section-5 items, returns; Loop de Looper declares goal-complete (or resumes if user introduced new state during human gates).

## PR lifecycle + push ownership

A multi-wave run shares ONE branch and ONE PR. The PR is created ONCE, EARLY — not deferred to "the end." Deferring orphans it: each wave reasons "not my job, the orchestrator opens it at the end," and the termination step historically had no PR action, so no actor ever created it. The run shipped seven green commits and zero PRs.

Model:

1. **Wave 1**, after the first successful commit: the brief carries `pr: create-on-wave-1` + `target.push: true`. `looper-commit` pushes (`git push -u origin <branch>`) and creates the draft PR (its Step 3), assigned `@me`. A real PR # now exists.
2. **Waves 2…N**: the brief carries `pr: existing #N` + `target.push: true`. `looper-commit` Step 2 detects the open draft and just commits into it (its "has open/draft PR" path); the push keeps the PR current per wave.
3. **Termination**: PR-finalization backstop (Step 4) asserts the PR exists before goal-complete, and creates it if some earlier wave missed it.

`pr: skip` is the ONLY suppressor of PR creation, and it is explicit + rare. "Don't flip to ready-for-review" is NOT `pr: skip` — the draft is still created; only the draft→ready flip stays the user's call. Collapsing those two is the exact bug this section exists to prevent.

Push is the orchestrator's call BY DESIGN — so the orchestrator must actually make it. An orchestrated run that never pushes can never open a PR: `gh pr create` requires the branch on the remote. `target.push: true` on every wave is not optional in orchestrated mode.

## Gate artifacts

Every gate the loop runs gets a durable on-disk record. A gate you can't audit isn't a gate: when the loop runs unattended (`--dangerously-skip-permissions`, no handback), the artifact is the only way to tell a real review from one the orchestrator merely narrated. Prose in the final report is NOT a substitute. See memory `[[feedback-loop-crew-gate-artifact]]`.

Write to `local/loops/<branch>/gates.jsonl` — one JSON line appended per gate event, never rewritten. The path is branch-keyed so resume runs and parallel branches don't collide; `jsonl` so a crashed run still leaves every prior gate intact.

Each line's field shapes are in `references/state-schemas.md`.

Hard rules:

- **`task_tool_available: false` ⇒ `ran: false` ⇒ no verdict.** Per memory `[[feedback-task-tool-availability]]`, the Task tool is sometimes absent in practice. A gate the loop _wanted_ to run but could not is logged as unavailable — NEVER as passed, NEVER with an invented verdict. Detect availability, don't assume it.
- **Verdicts are cited verbatim** from agent output, matching the `## Voice + style` no-paraphrase rule.
- **`outcome` is the structured twin of `verdict` for a refutation-posture reviewer — never its replacement, and NOT every crew agent's field.** Only a reviewer whose mandate is _refute-or-promote_ sets it: `the-diamantaire` (its kill-mandate posture) is the one today; the set grows only if another agent adopts that posture. Such a reviewer normalizes its `verdict` to `refute` (a defensible defect that blocks the diff) or `promote` (survived review) so the log is machine-queryable without paraphrasing away the verbatim line. **Every other line carries `outcome: null`** — a non-refutation crew agent (voice/test/doc/refactor findings have no refute/promote shape), a `pre-build-specialist` gate, a `wave-retry`/`stale-skip` event, a `ran: false` line. It never overwrites `verdict`; both ride on the line.
- **`verified_by` records whether THIS gate's verdict was backed by a runnable check the agent actually executed, or rests on judgment.** `executable` when the agent ran a check — a test, a lint, an oracle, a `jq` assertion — whose result gated the verdict (the same executable-over-judgment axis `looper-verify` draws in `## Executable verification function (where an oracle exists)`); `llm` when the verdict rests on model reasoning alone; `null` only when `ran: false` (nothing gated). It applies to any ran gate, crew or specialist — a code reviewer with Bash _can_ run a check to confirm a finding (`executable`), or reason to it (`llm`). This is the drift-audit the field exists for: a log whose verdicts are all `verified_by: llm` shows no verdict was ever empirically backed — the "unanimous consensus, no empirical check" failure (custodian #21 E-1/E-2) becomes greppable, not buried. Never label a line `executable` without an actual runnable check behind it; an unbacked judgment is `llm`, same honesty as `ran: false`.
- **Provenance is machine-checkable, not just documented.** The fields earn their keep only if a lint enforces them, so validate a run's log with a `jq` pass over `gates.jsonl` (the same file `scripts/custodian-history.sh` already `jq`-parses) — every ran verdict-bearing gate (`crew` or `pre-build-specialist`) carries `verified_by`, and a refutation-posture reviewer's crew line also carries `outcome`. The lint command + its scope/legacy-exemption notes are in `references/state-schemas.md`. `wave-retry` / `stale-skip` events aren't verdict-bearing gates, so neither field is required on them. Extend the `.agent ==` clause if another agent takes the refutation posture. A `verified_by: llm`-only run is _valid_ but _flagged_ — the lint proves the fields are present, not that the run used an executable check.
- **Write before acting on the result** — log the crew pass before looping back or resetting counters (step 3), log the specialist gate before re-dispatch (step 2b). A blocker found is still a gate that ran.

The final report's crew/gate claims must be backed by these lines. If `gates.jsonl` shows a gate as `ran: false`, the report says so plainly — it does not claim the gate passed.

## State tracking

Run state lives on disk, NOT only in the parent's working memory. A long unattended run gets context-compacted; queue + counters held only in-context can evaporate, and a resume that re-derives them by grepping commit messages is lossy. The snapshot is authoritative.

Three files under `local/loops/<branch>/`, all branch-keyed so resume and parallel branches don't collide:

- **`gates.jsonl`** — append-only audit log. One line per gate event, never rewritten. Source of truth for _what gates ran_.
- **`run-state.json`** — mutable position snapshot. Rewritten after every wave and every crew pass. Source of truth for _where in the queue we are_.
- **`wave-N.jsonl`** (+ its `wave-N-plan.md` artifact) — append-only per-wave step journal, written by `the-looper`, NOT by the orchestrator. Source of truth for _how far into a wave the executor got_. Contract in `agents/the-looper.md` `## Step journal`.

Different shapes, different jobs: the jsonl is a log you append, the json is a snapshot you overwrite. The journal is a separate file from `run-state.json` out of necessity, not taste — the orchestrator rewrites that snapshot wholesale (write-tmp-then-`mv`), so an executor appending step lines into it concurrently would lose them to the next `mv`. Granularity matches ownership: the orchestrator checkpoints WAVES, the executor checkpoints STEPS inside one. Write `run-state.json` **atomically** — write `run-state.json.tmp`, then `mv` it over `run-state.json` — so a crash mid-write never leaves a half-file. Write it BEFORE acting on the budget governor or crew trigger (step 2c), so a halt still leaves a resumable snapshot.

The `run-state.json` shape + the `usage` sub-object's fields are in `references/state-schemas.md`, alongside the journal's own line shapes and reader rules.

Resume mode (`/loop-de-looper resume`):

- **Primary**: read `run-state.json`. Branch matches + file present → trust it for queue, counters, PR, last-crew. Reconcile `last_crew_wave` against `gates.jsonl` crew entries (jsonl wins on any disagreement about _what ran_).
- **Mid-wave**: a wave the snapshot shows `pending` may still have a partly-finished journal. Re-dispatch it normally — do NOT parse the journal to decide which steps to hand it. `the-looper` reads its own journal and resumes at its next unfinished step; the orchestrator owns wave granularity, the executor owns step granularity.
- **Fallback only** (file missing / corrupt / pre-snapshot run): re-derive as before — re-run scope, diff `git log main..HEAD` for shipped waves, re-derive counters from git stat, grep commit messages for last crew. Lossy; the snapshot exists so this is the exception, not the path.

## Budget governor

The wave queue is bounded (scope caps it ≤15), but **corrective waves and stuck-wave retries are not** — a crew blocker spawns a fix wave, which can spawn another, and each retryable stop spends a from-scratch retry. That churn, not the queue, is the runaway shape. The governor rails on what the orchestrator can actually observe (wave counts, churn) — NOT token spend, which a Skill-driven orchestrator has no reliable way to meter. No fake gauge.

Evaluated in step 2c after `run-state.json` is written, before the crew trigger:

| Rail                      | Default | Hit →                                                                                                                                  |
| ------------------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `max_total_waves`         | 25      | STOP + escalate: queue + corrective waves exceeded the ceiling                                                                         |
| `max_corrective_waves`    | 6       | STOP + escalate: too many crew-blocker fixes; drift is structural, not patchable                                                       |
| `consecutive_no_progress` | 3       | STOP + escalate: 3 waves running without shipping net-new queue work (thrash)                                                          |
| `max_wave_retries`        | 4       | STOP + escalate: too many waves needed a from-scratch retry; the goal is systematically too hard for the executor, not a one-off wedge |
| `scaffolding_only_correctives` | 2  | STOP + escalate: consecutive correctives touched only test scaffolding; the crew is reviewing the harness, not the fix                 |

The scaffolding rail catches a shape the wave counters cannot see. A crew pass against a source-text oracle finds a real hole every time — another spelling, another file, two boxes trading values — so each corrective ships green and earns the next one, and `consecutive_no_progress` never fires because every wave shipped something. Meanwhile the product fix has been finished since wave 1. Two correctives in a row that move no product file means the run is defending its own test, and the answer is usually to delete the test rather than widen it (observed: a 13-line viewport fix that shipped correct in wave 1, then spent four waves rebuilding a 400-line scanner around it).

Hitting a rail is a STOP, not a failure — same discipline as a scope refusal. The persisted `run-state.json` makes the halt resumable: surface the state report, let the user raise a ceiling or redirect, then `/loop-de-looper resume`.

Defaults are tunable per project — see the single canonical override block in `## Crew trigger + budget tuning`.

## Usage-window guard

The governor rails on _churn_; this rails on the _account usage window_ — the 5-hour and weekly limits a long run can exhaust mid-flight. A run that burns its window dry doesn't fail cleanly: the next dispatch hard-errors partway, orphaning a half-built wave. This guard stops that at the wave boundary instead, then resumes itself when the window clears.

**This is NOT the token-metering the governor refuses.** The governor's "no fake gauge" rule bans _inventing_ a spend number a Skill orchestrator can't read. This guard reads a **real first-party observable** — the enforced rate-limit window the host returns on every API response (`anthropic-ratelimit-unified-*` headers), the same window Claude Code's own statusline renders — so it clears the same honesty bar the context-pressure handoff does ("observed, not metered"). The signal is measured, not guessed.

- **Read the real window at the wave boundary.** In step 2c, after the governor, run `~/.claude/scripts/usage-window-probe.sh` (deployed there from the definitions repo, so it resolves from any target repo's cwd; a repo-relative path would not). It locates the Claude Code OAuth token (macOS Keychain service `Claude Code-credentials`, or a `~/.claude/.credentials.json` fallback), fires one `max_tokens:1` probe at `/v1/messages`, and parses the `anthropic-ratelimit-unified-{5h,7d}-{utilization,status,reset}` response headers into one JSON line: `{read_ok, five_hour:{utilization,status,reset}, weekly:{...}, representative}`. `utilization` is a real 0–1 fraction of the enforced window; `reset` is a unix epoch. This is a read, not a wave — it does not touch counters. It costs one tiny call, which is why it runs at the boundary and never in a loop. It is NOT ccusage (a different axis — see the probe-unavailable bullet on why there's no cost-axis fallback).
- **Pause at 95%, or on a server reject.** Do NOT dispatch the next wave if, for the 5-hour OR the weekly window, `utilization >= 0.95` OR `status == "rejected"`. `status` is the server's _authoritative_ reject signal; `utilization` is only the proxy — a window can reject below 95% on a claim- or model-specific sub-limit, so honor both (`allowed_warning` corroborates the utilization threshold but is not itself a hard stop). A window whose `utilization` is `null` (header absent) is _unread_ — skip that window, never read null as 0. Threshold is tunable (`## Crew trigger + budget tuning`); the default is 95% of the _window utilization_, never a dollar figure (a cost cap is one account's private guardrail, not a portable rule).
- **Finish the in-flight wave first, never interrupt it.** Same wave-boundary discipline as every other halt — let the current dispatch commit at its clean point, write `run-state.json`, pause BEFORE the next dispatch (`## Context-pressure handoff`).
- **This halt self-resumes — it does not wait on a human.** Unlike a governor rail or context pressure (which need the user to raise a ceiling or start a fresh context), a usage pause clears on a _known schedule_. Schedule a wakeup (`ScheduleWakeup`) off the over-threshold window's `reset` (unix epoch **seconds** — keep `now` in seconds too): `min(3600, max(60, reset - now))` for a 5-hour pause; for a _weekly_ pause, back the cadence off to `min(3600, max(1800, reset - now))` — a 7-day window drains slowly, and hourly re-probes would spend ~150 calls against the very window they wait on. If the runtime clamps the delay, chain wakeups. Each wake RE-PROBES. **The resume gate is the fresh probe, stated once: resume ONLY when the re-probed `utilization < threshold` AND `status != "rejected"` for every window.** `now >= reset` (the snapshotted epoch) is corroboration that the window _should_ have rolled, never the resume trigger on its own — trusting elapsed wall-clock alone misfires on a slept Mac, a clock skew, or a paused laptop. Reschedule if the fresh probe still trips the pause gate.
- **Report both the pause and the auto-resume.** The halt line names which window is over, the observed utilization as a percent, and the scheduled wake (`~HH:MM local, when the 5-hour window clears`), AND still emits `` `/loop-de-looper resume` `` so the user can force-resume earlier if they've raised their own limit. Names the next command either way (`## Voice + style`).
- **Probe-unavailable ⇒ do NOT guard, and say so.** The probe emits `{read_ok:false, reason}` when it can't read the window — `no_credentials` (non-Claude-Code host, creds elsewhere), `token_expired` (refresh is the Claude Code client's job, not the guard's), `probe_failed` (no network — but then the loop can't dispatch a wave anyway), `no_ratelimit_headers` (API drift), or a macOS Keychain ACL prompt a headless run can't answer. Per `[[feedback-task-tool-availability]]`: log that the usage read did not run, continue WITHOUT a usage pause (the governor + context handoff still bound the run), and note in the report that the window was unguarded this run. NEVER invent a percentage or a fake pause — an unread window is unread, not "0%". There is deliberately no cost-axis fallback. ccusage was considered and dropped: it reads a different axis (dollar/token _cost_ against a limit it can't know, so any percent off it is exactly the fabricated gauge the governor already bans). In the network-down case it can't run either; in the others (`no_credentials`, `token_expired`, Keychain-ACL) it _would_ run — but its cost number doesn't match the enforced rate window, so honest "unguarded" still beats a plausible-but-wrong percent. The residual blind spot is real and accepted: a headless run whose creds sit in a nonstandard path and whose window is genuinely near exhaustion goes unguarded (the governor + context handoff remain the backstop).

## Context-pressure handoff

A long unattended run fills the context window. Pushed past that, recall degrades: the in-context queue and counters get summarized lossily, mid-wave reasoning rots, and a wave dispatched into a degraded context ships worse work than the same wave from a clean start. The wave boundary is the safe place to stop — `run-state.json` is written there (step 2c, atomic), so a halt-and-resume across that line loses nothing.

So context pressure is a **wave-boundary handoff**, not a mid-wave abort:

- **The signal is observed, not metered.** Same honesty as the budget governor's no-token-gauge rule: a Skill orchestrator can't read an exact context-window %, so don't invent one. The real signals are coarse and real — a compaction/summary event fired this run, OR the orchestrator had to re-derive in-context queue/counters from `run-state.json` because it lost them (the `## State tracking` fallback firing mid-run is itself the tell). Treat either as pressure.
- **Halt at the NEXT wave boundary, never mid-wave.** Let the current `the-looper` dispatch finish its wave (it commits at a clean point), write `run-state.json`, then stop BEFORE dispatching the next wave. Never interrupt a wave to "save context" — a half-built wave is the loss this avoids, not the cure.
- **It's a clean handoff, not a stuck stop.** Because state is persisted, the halt report is a normal resumable one: surface where the queue stands and end with the literal `` `/loop-de-looper resume` `` (per `## Voice + style`). The resume re-dispatches from the snapshot into a fresh context — the same "restart to escape a rotted context" move 2b-retry uses for a wedged wave, applied to the whole run.
- **Don't pre-empt needlessly.** A run that still has clear headroom does not stop early — this fires on observed pressure near a boundary, not on wave count. Wave count already has its own rail (`max_total_waves`); this is the orthogonal context axis.

## Stop conditions

- **Nonbeliever STOP verdict**: hard rule conflict / smuggled user-authority decision / required-gate substitution → STOP before scope, surface nonbeliever output (`## Protocol` Step 0)
- **Scope refuses goal**: open-ended, conflicts with rules, candidates all high-risk same-specialist → STOP, surface scope output (`## Protocol` Step 1)
- **Plan stops**: research output ambiguous, mechanized infra missing, all recovery options fail → STOP, surface plan output
- **the-looper stops**: verify fails twice same root cause, review verdict `rethink`, gate not pre-flighted → ONE from-scratch retry first if retryable, STOP + surface only after the retry also fails or immediately if non-retryable (`## Protocol` 2b-retry)
- **Crew finds blocker requiring rollback**: drift past patchable → STOP, escalate to user (no auto-revert commits)
- **Budget governor rail hit**: `max_total_waves` / `max_corrective_waves` / `consecutive_no_progress` / `max_wave_retries` / `scaffolding_only_correctives` exceeded → STOP, escalate with the persisted state report (`## Budget governor`); resumable after the user raises a ceiling
- **Context pressure at a wave boundary**: a compaction fired or in-context state had to be re-derived from `run-state.json` → finish the wave, halt BEFORE the next dispatch, emit `/loop-de-looper resume` (`## Context-pressure handoff`). Clean handoff, not a failure.
- **Usage window at/above 95% at a wave boundary**: active 5-hour or weekly limit near-exhausted → finish the wave, pause BEFORE the next dispatch, schedule a self-resume (`## Usage-window guard`). A PAUSE, not a STOP.
- **Queue exhausted, required-not-loopable items remain**: surface explicit list, await user action
- **User intervenes**: any user message during run = stop signal; current wave completes, then halt

Stopping not failure. Looping past known blocker = failure. Looping past a budget rail = failure.

## What loop-de-looper does NOT do

- Does NOT execute waves directly — every wave goes through `the-looper`, no bypass (`inline` sizing is not an exception: the loop never starts, it hands the one-liner back and exits).
- Does NOT skip crew passes — trigger fires → pass runs, no "ship anyway" (`single-wave` sizing skips the crew _cadence_, an up-front sizing decision, not a mid-run skip).
- Does NOT auto-revert commits when crew finds a blocker. Surfaces; user decides.
- Does NOT silently swap specialist gates for built-in checks. `ESCALATE` → orchestrator invokes specialist; no "I checked it myself."
- Does NOT let a UI-touching wave build without accessibility-lead — UI-glob mandates the gate up-front, plan `ESCALATE` is the reactive backstop, neither skippable (`## Protocol` 2b pre-mandated).
- Does NOT record a gate as passed when it didn't run — Task-tool-unavailable / never-invoked logs `ran: false`, report says so; no invented verdicts, no prose-only gate claims (`## Gate artifacts`).
- Does NOT flip draft PR to ready-for-review (user's call); DOES create the draft (wave 1 or termination backstop) — creating ≠ flipping (`## PR lifecycle + push ownership`).
- Does NOT declare goal-complete with committed work and no PR. PR finalization (Step 4) is mandatory on every path.
- Does NOT revert a PR state it did not itself set — a ready flip or a close belongs to the owner; surface it, never `gh pr ready --undo`, never open a replacement for a closed PR (`## Protocol` Step 4).
- Does NOT overwrite a user-edited PR body in the structured-recap refresh — a `pr.body_sha` mismatch means augment additively or leave it, with the user's lines byte-identical and exempt from the ghostwriter pass (`## Protocol` Step 4).
- Does NOT defer PR creation to "the end" with no owner, and does NOT bundle "no PR" with "don't flip to ready" in a brief (`## PR lifecycle + push ownership`).
- Does NOT re-scope mid-run. Goal shifts → user issues a new run.
- Does NOT loop unbounded — budget governor caps total/corrective/no-progress/retry churn (rail hit = STOP), railing on observed churn never metered token spend (`## Budget governor`).
- Does NOT invent a usage percentage or dispatch into a near-exhausted window — reads the REAL rate-limit window, pauses at 95%, self-resumes; probe-unread logs not-run + unguarded, never a fabricated pause/percent or cost-axis substitute (`## Usage-window guard`).
- Does NOT defer a wave's cross-file-incompleteness flag to the crew — a dangling reference it created is triaged immediately (`## Protocol` 2b-flags).
- Does NOT retry a deterministic stop (write-gate, governor rail, scope refusal — same wall every time, bubble up); only a non-deterministic stop (verify-twice, `rethink`, no-progress) earns ONE fresh-context retry reverting to the next ranked plan, never a resume — and an interrupted wave that never handed back is a resume, not a retry (`## Protocol` 2b-retry).
- Does NOT keep run state only in-context — queue + counters persist to `run-state.json` (atomic) every wave, and the executor journals its own steps to `wave-N.jsonl`; in-context is a cache (`## State tracking`).
- Does NOT dispatch into a degraded context or interrupt a wave mid-flight — on observed pressure it halts at the NEXT wave boundary and hands off with `/loop-de-looper resume`, never a mid-wave abort or invented context-% gauge (`## Context-pressure handoff`).
- Does NOT halt without naming the next command — every STOP / escalation / handoff / required-not-loopable termination ends with the literal runnable line (`## Voice + style`).
- Does NOT skip nonbeliever pre-flight or halt on a mere challenge — only a STOP verdict halts; PROCEED-WITH-NOTES carries notes into scope (`## Protocol` Step 0).
- Does NOT skip run-level learn on a success path — the only step diagnosing the orchestration itself; it only WRITES lessons, does NOT gate/flip/revert/re-open the run (`## Protocol` Step 4).
- Does NOT let recap decide, fix, or flip anything, or replace the structured exit report — read-only narration on top; facts trace to `gates.jsonl` / git log (`## Protocol` Step 4).
- Does NOT invent diff facts in the structured-recap PR-body refresh — tree/flags/hunks are byte-exact excerpts of the real whole-run diff, the wireframe a diff-constrained reconstruction, anything beyond the diff marked `inferred:`, secrets redacted (`## Protocol` Step 4).
- Does NOT block termination on a failed structured-recap refresh — best-effort enhancement, never a gate; a refresh that errors logs and continues to goal-complete (`## Protocol` Step 4).

## Crew trigger + budget tuning

Crew-trigger defaults: every 4 waves OR 30 cumulative file changes, whichever first. Budget governor defaults: `max_total_waves=25`, `max_corrective_waves=6`, `consecutive_no_progress=3`, `max_wave_retries=4`, `scaffolding_only_correctives=2` (see `## Budget governor`). Usage-window guard default: pause at `95%` utilization of the active 5-hour or weekly window (see `## Usage-window guard`).

Single canonical override block in the project CLAUDE.md:

```
## Loop de Looper
- crew-trigger: waves=N, files=M
- budget: max-waves=N, max-corrective=N, no-progress=N, max-retries=N, scaffolding-only=N
- usage-pause: pct=N   # 0 disables the usage-window guard
```

Tighter triggers + budgets for high-drift domains (palette, auth surface) where churn signals a wrong approach early. Looser for long mechanical cleanup loops that legitimately run many waves.

## Voice + style

Reports to user: structured, scannable. Per-wave status line. Crew pass summary. Final state report. Match lean voice of `looper-commit` and `looper-learn`.

Cite agent outputs verbatim when surfacing blockers; no paraphrase. Per memory `[[feedback-verify-upstream-gate-claims]]` and `[[feedback-task-tool-availability]]`, orchestrator's job = surface signal, not summarize away.

**Every halt names the next command — literally.** A STOP, an escalation, a budget-rail halt, a context-pressure handoff, or a required-not-loopable termination ends with the exact copy-paste line the user runs next — not a described intent the user has to translate. The run knows its own resume path; spell it:

- Resumable halt (governor rail, context pressure, user-intervention pause) → `` `/loop-de-looper resume` `` (the persisted `run-state.json` makes it exact).
- Usage-window pause → names BOTH the auto-resume and the manual override: "paused on the 5-hour window (96%), auto-resume scheduled ~HH:MM local when it clears; `` `/loop-de-looper resume` `` to force earlier if you've raised your limit." The scheduled wake IS the primary next step; the command is the escape hatch (`## Usage-window guard`).
- Custodian-style follow-on (a proposal to apply) → `` `/looper-custodian apply #<issue>` ``.
- A user-authority decision the run can't make → state the decision, then the command that continues once they've decided.

A halt report that says "the user should re-run when ready" without the runnable line is the gap this rule closes: the next action is one paste, never an inference.
