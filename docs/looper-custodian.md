# Looper Custodian — design rationale + decision log

Status: **built.** Operational spec (phases, artifacts, scheduling, the full
"what it does") lives in `skills/looper-custodian/SKILL.md` — that is the source
of truth. This doc holds only what the skill doesn't: _why_ it exists, _why_ the
choices are what they are, and the _decision record_. Don't duplicate mechanics
here — if a phase's behavior changes, it changes in `SKILL.md`.

## Why it exists

The looper system learns and tidies _per run_: `looper-learn` writes lessons at
the end of each wave and orchestration; `the-turncoat` streamlines an agent or
skill when asked. Nothing runs _across_ runs and _across_ repos on a cadence.
Over weeks that leaves three rots no per-run step can see:

- **Memory rot** — `MEMORY.md` + memory files accumulate duplicates and
  contradictions; a later memory supersedes an earlier one but the earlier is
  never removed, so recall surfaces stale guidance.
- **Artifact litter** — `local/loops/<branch>/` keeps `run-state.json` +
  `gates.jsonl` for branches long since merged and deleted.
- **Lost cross-run signal** — the same crew finding recurs across many runs and
  repos, but no one looks at the aggregate, so the systemic fix never surfaces.

Custodian is the scheduled, cross-run, cross-repo maintenance layer. It does not
replace `looper-learn` or `the-turncoat` — it batches and aggregates what they
do, plus the memory-contradiction GC neither does today.

## Governing principle: custodian PROPOSES, human DISPOSES

The spine of the design, and the reason it's split into auto vs gated phases.

An unattended job that auto-edits memories or agents is exactly the "merging
outpaces comprehension" failure the loop-engineering sources warn about.
Auto-deleting a memory because a later one "contradicts" it can silently destroy
a deliberate exception. So:

- **Read-only / regenerable work runs automatically** — artifact GC, memory
  audit report, cross-repo digest, research digest.
- **Anything that writes a memory or an agent is propose-only** — it lands as a
  checkbox in the report issue and applies ONLY through `apply` after a human
  ticks the box.

This is the same discipline the loop already holds (does NOT auto-revert
commits, does NOT flip draft→ready). Carried rails follow from it: no memory
deleted on contradiction alone without both sides quoted verbatim; no agent
rewritten except via `the-turncoat` on an approved target; bounded proposals per
run; unavailable tool ⇒ `ran: false`, never an invented outcome.

## Why these mechanisms (the non-obvious choices)

- **Report = GitHub issue, not a local file.** The run is an unattended cron and
  `local/` is gitignored — a local report would be both invisible (nobody
  watching) and unreachable by a later `apply`. The issue is notification +
  durable report + checkbox approval surface + stable ref for `apply`, all at
  once. Quiet week → no issue → no noise.
- **Local launchd, not cloud `/schedule`.** Phases A/B/C read local-only state
  (`local/loops/` scratch, the `~/.claude` memory dir, `gates.jsonl` across
  local repos) an isolated cloud session can't reach. The host has to be the dev
  machine. (This contradiction — local artifacts under a "cloud cron" plan —
  was caught only when the host got concrete; see decision 6.)
- **External research promoted to a core phase, not a stretch opt-in.** It's
  read-only and auto-applies nothing, so it carries the same risk as the
  cross-repo digest — no reason to gate it behind a separate opt-in.
- **Phase C history index is derived, never authoritative.**
  `local/custodian/history-index.jsonl` is a rebuildable cache of `gates.jsonl`,
  so incremental ingest is a speed/token optimization — a corrupt index is one
  `history --rebuild` from correct, **provided the source still exists**. The
  original claim here was "can never lose data"; the 2026-07-13 incident
  falsified it: rebuild-ability dies the moment Phase A reaps the source
  `gates.jsonl`, so ingest must strictly precede GC (decision 13). That
  regenerable-scratch status (same as `local/loops/`) is exactly why an
  unattended cron may write it automatically: it stays on the read-only/auto
  side of the propose-dispose line.

## Decision log

Greenlit 2026-06-27 (open questions resolved before build):

1. **Repo list** — explicit, not auto-discover. `linklater`, `tuffgal`,
   `tuffgal-action`, `agents-of-shield-if-shield-is-ai`, `rss-reader`. An
   unattended job scanning every repo it can reach is the unbounded reach the
   propose/dispose discipline exists to prevent.
2. **Phase A aggressiveness** — GC immediately on merged, no grace window. The
   merge already comprehended the work and `local/` is regenerable scratch.
3. **Phase D trigger** — checkbox approval in the report issue, then
   `/looper-custodian apply #<issue>`. Explicit + idempotent, no fuzzy parsing.
4. **Cadence** — weekly, all phases on one tick.
5. **External research** — promoted from stretch opt-in to **Phase E**,
   integrated from the start (rationale above).
6. **Cron host** — local launchd, not cloud `/schedule` (rationale above).
   Decided during the build when the cloud host's inability to reach local state
   surfaced.

Refined 2026-06-27 by the first supervised run (commit `2d8d767`):

7. **Phase A: merged overrides a lingering local branch.** Original rule was
   ambiguous on whether a leftover _local_ branch blocks reaping. It doesn't — a
   merged local branch is cruft, not a resumable run. "Merged" is tested by
   ancestry OR a merged PR (squash-safe); only an open PR or genuinely-unmerged
   work blocks GC. Backstopped by enabling `delete_branch_on_merge` on all five
   repos so the remote signal stays clean.
8. **Phase B: deterministic, coverage-counted enumeration.** The audit must not
   depend on a subagent's bash discovery (it silently under-audited 26/63 on the
   first pass). The orchestrator owns enumeration; delegated reads get explicit
   paths + Read-only; `files_audited < files_total` ⇒ a `partial` verdict, never
   a clean bill on uncovered files.

Refined 2026-06-29 from an external-research review (this pass):

9. **Phase D is previewable + reversible.** `apply` snapshots every target to a
   `backup-*/` dir before its first write; `apply … --dry-run` prints the exact
   before/after and writes nothing; `undo` restores the last snapshot. The
   propose/dispose split already gated _commitment_; this makes the committed
   step approve a _previewed_ diff and a regretted one revert in one command.
   Convergent signal — brianlovin's `sync.sh` (timestamped backup + `undo` +
   `--dry-run`), clig.dev (preview before consent), and the "most-capable-agent"
   prompt (checkpoint-before-destructive) all pointed the same way.
10. **Phase B gains distillation.** Beyond de-dupe + contradiction, the audit
    now proposes consolidating 3+ episodic notes that instance one rule into a
    single semantic/procedural memory (`B-distill-<n>`), linking the instances
    as evidence. A flat de-dupe misses the pattern the dir only implies.
11. **Phase E requires a local-validation method.** An external-research
    candidate is only an actionable checkbox if it carries a runnable eval /
    shadow run / replay (`validate-by:`); otherwise it stays informational. The
    highest-variance input shouldn't enter the apply path on an external
    author's say-so — same discipline as `looper-verify`'s executable VF.

Refined 2026-07-03 from a tool-scan (`ctx` / `deptrust` / Safari MCP):

12. **Phase C gains a cited, incremental history index (the `ctx` graft).**
    `ctxrs/ctx` indexes agent-session logs into a searchable local store and
    returns ranked _cited_ matches (~50× token-efficient vs a raw scan) with a
    `--file` filter. `gates.jsonl` is already our structured session log, so the
    graft is _retrieval, not a new store_: Phase C now maintains
    `local/custodian/history-index.jsonl` (append-only, one record per gate line
    - `repo`/`branch`/`files`/`cite`), ingests only new runs each week instead of
      re-scanning all history, and a read-only `history <query>` verb serves ranked
      cited lookups (incl. `--file`, re-created from git). Faithful to ctx's
      _pattern_; rejects its _substrate_ — no Rust binary, no SQLite. That is the
      `no-third-party-hosted-tool-reliance` directive in practice: mine the pattern,
      not the tool. The index is a derived cache, `--rebuild`-able, gitignored scratch.
      `deptrust` (dep-CVE guard) and the Safari MCP were scanned in the same pass and
      left un-adopted: deptrust is a universal-Claude-Code concern with near-zero
      surface in this markdown-only repo (revisit if a code repo in the list churns
      deps), and the Safari browser-drive pattern is already covered by `/verify` +
      the playwright accessibility agents.

Refined 2026-07-13 from the reap-before-ingest incident:

13. **Ingest strictly precedes GC (run order C → A → B → E) + per-dir
    ingest-guard.** The 2026-07-13 scheduled run executed the spec'd A-first
    order while `history-index.jsonl` did not yet exist: Phase A reaped 11
    merged-branch dirs whose `gates.jsonl` lines had never been ingested,
    destroying the index's source (recovered only from an off-site Backblaze
    backup — APFS snapshots and Time Machine had nothing). Two fixes: (a) the
    maintenance run now executes Phase C's ingest before Phase A's reap, and
    (b) Phase A gained a hard ingest-guard — a dir with any `gates.jsonl` line
    missing from the index (anti-join by `cite`) is kept and logged
    `kept (unindexed — ingest gap)`, never reaped, so a partial or failed
    ingest degrades to deferred GC instead of data loss. Same run also
    exposed the wrapper as silent-on-failure — two consecutive Mondays died to
    `API Error: Connection closed mid-response` with no alert — so
    `looper-custodian-cron.sh` gained retry-with-backoff (3 attempts) and a
    loud failure path (macOS notification + `Custodian run FAILED <date>`
    GitHub issue).

Refined 2026-07-16 from an 8-article agent-harness audit (Osmani, Cloudflare,
LangChain, Ambiance, wakamoleguy, Hobday, Elliot Smith, capn-hook):

14. **Phase B gains a staleness condition (the capn-hook graft).** capn-hook
    invalidates a memory entry by content hash — a recall backed by a file the
    file no longer backs is pruned. Grafted as a fourth Phase B condition:
    a memory citing a `file:line` / script / symbol / flag that no longer
    resolves is flagged. Two dispositions, split into two verb tags so Phase D's
    one-tag-one-write apply stays unambiguous: `B-repoint-<n>` (target MOVED —
    non-destructive in-place cite edit) and the existing `B-retire-<n>` (target
    GONE). Resolution is existence-plus-`grep` against the _right_ root
    (user-global vs repo), never exact-line — line drift (`:42`→`:47`) is not a
    dead reference, and a moved target is a re-point, not a retire (the same
    "provably gone, not merely moved" line `loop-de-looper`'s stale-candidate
    pre-check draws). A retire on a dead cite carries the failed relocation
    search quoted verbatim, so the human verifies _gone_ not merely _moved_ — a
    sibling of the "no delete on contradiction alone" rail. Faithful to
    capn-hook's _pattern_ (hash-invalidation of code-citing recalls); rejects its
    _substrate_ — no `.capn/` store, no SQLite, just a path check over the memory
    dir Phase B already reads. `no-third-party-hosted-tool-reliance` in practice.
    Local eval at adoption found 0 current stale hits (preventive, not urgent)
    but surfaced the root-ambiguity failure mode, which is why right-root
    resolution is mandatory in the spec. The other audited pieces were already
    covered: `flexible-gates` is the existing "always gate, rigor scales with
    risk" design (nonbeliever sizing + risk-weighted crew trigger), Ralph
    loops / durable-state / adversarial-verify / ranked-plans / budget-rails all
    have direct analogues, and the two remaining residues (shallow-pass evidence,
    unmechanized-constraint-as-ignored-signal) stayed informational for want of a
    replay proving a real miss — Phase E discipline applied to an inbound idea.

Refined 2026-07-20 from the bg-wait-ceiling incident:

15. **Phase E's ceiling is an unmeasured margin, and a ceiling-kill is
    resumable, not silently dropped.** The 2026-07-20 run backgrounded Phase
    E's `deep-research` and then hit the harness
    `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` default while the fan-out was still
    running. That run's `cron.log` line 2 is the whole of what is on disk
    about it: `Background tasks still running after 600s; terminating. Set
CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 to wait indefinitely.` The
    harness terminated the workflow — but a ceiling-kill still exits 0, so the
    wrapper counted it a clean success: no `Custodian report` issue was ever
    opened and ~1.4M tokens of already-completed research were thrown away with
    no trace but a drained session limit. Sibling failure mode to decision 13's
    silent-on-failure wrapper — a half-done run that _looks_ done is as bad as a
    dead one that looks alive. Three fixes: (a) the wrapper raises the ceiling to
    30 min, to give a normal Phase E room to finish within the end-of-turn wait
    so Phase F runs — **how much room that is was never measured**, and the
    original wording (`3ce7156`: "30 min clears an observed ~11 min
    deep-research fan-out with headroom") read the 30 min as proven. Two
    things are wrong with that. The sourced figure is the 600s above — the
    point at which the harness KILLED a fan-out that had not finished, so it
    is a **lower bound** on that fan-out's duration and nothing at all is
    known about the rest of it. And the `~11 min` itself has no source: it
    entered with `3ce7156`, and searching that run's artifacts for `11 min` —
    or for the `644` seconds it would imply — returns nothing. Take that as
    stated rather than reproduced: `local/custodian/` is gitignored, so neither
    search runs from a clone, and the only figure that run produced for the
    kill is the 600s in the `cron.log` line quoted above. 30
    min is therefore an unmeasured margin over a lower bound, not a headroom
    figure, and it stands unchanged until a live Monday measures a fan-out
    that actually completes; (b) a ceiling-kill is detected (the harness'
    `Background tasks still running after …` marker in the run log), turned into
    a loud resumable state — a `resume.json` breadcrumb + a
    `Custodian INCOMPLETE <date>` issue — and **never retried** (a retry re-runs
    C/A/B and re-hits the ceiling on E, compounding the waste); and (c) a new
    `/looper-custodian resume [<date>]` mode replays only the unlogged tail
    (Phase E → report), reusing the C/A/B already in `custodian-log.jsonl` and
    recovering Phase E's findings from the killed workflow's on-disk journal when
    reachable. Each cron attempt now runs under a known `--session-id` so resume
    can locate that transcript — `resumeFromRunId`'s agent cache is same-session
    only, so the persisted journal is the cross-session handle. `custodian-log.jsonl`
    is the resume source of truth: a phase counts as done iff it logged, never on
    a subagent's say-so (the same executable-record discipline as decision 8).
16. **Phase E gets a usage-window gate — probe before the expensive dispatch.**
    The same 2026-07-20 review noted the deeper exposure behind the ceiling-kill:
    Phase E is the run's one large token sink (~1.4M tokens) and the custodian
    had NO usage-window guard at all — unlike `loop-de-looper`, whose guard reads
    the real `anthropic-ratelimit-unified-*` window and pauses at a wave boundary.
    The custodian has no wave loop, so the C → A → B → E order stands in for
    one and E is the dispatch worth gating — a substitution that holds only
    while the order is executed serially, since a phase boundary is a
    checkpoint only when it is a quiet moment (decision 24). So E now runs
    `scripts/usage-window-probe.sh` before invoking `deep-research`: at ≥95%
    utilization or a `rejected` status on the 5-hour or weekly window it DEFERS E
    — logs `deferred (usage-window)`, writes the `resume.json` breadcrumb, and
    still ships the report on C/A/B with an `E: deferred … resets ~HH:MM` line —
    rather than burning the window dry mid-fan-out and orphaning both the research
    and whatever the user does next. `read_ok:false` ⇒ run E unguarded and say so,
    never a fabricated pause (same probe-unavailable honesty as the loop's guard).
    `resume` re-probes before re-running E, so a too-early resume re-defers instead
    of slamming a still-hot window. Reuses the loop's existing probe and threshold
    — one real observable, no cost-axis guess (`[[reference-usage-window-real-ratelimit-headers]]`,
    `no-third-party-hosted-tool-reliance`).
17. **The report body is sanitized by default because the target repo is
    public.** The 2026-07-20 resume finished C/A/B/E and then the `gh issue create`
    was denied by the auto-mode classifier: `agents-of-shield-if-shield-is-ai` is a
    **public** repo, and the drafted body carried other repos' branch names + PR
    numbers, crew agent code names, and `~/.claude/…` absolute paths — excess
    internal detail for a public recipient. On the interactive resume that's a
    solvable prompt; on the unattended weekly cron it is a **hard block** — the
    headless `claude -p` can't clear the classifier, so a non-sanitized body would
    kill Phase F the same way the ceiling killed Phase E (decision 15): work done,
    nothing published. The fix moves the discipline into the spec rather than
    relying on a human to trim each week. The full per-line detail already lives in
    `custodian-log.jsonl` (gitignored, local), so the issue body is written to carry
    only what a human needs to _approve a checkbox_: Phase A/C give counts + a
    repo-agnostic gloss (exact `repo/branch:line` cites stay in the log), crew
    agents are named by role not code name, and memories/skills are named by bare
    slug not filesystem path. What stays verbatim is Phase B's quoted memory
    _evidence_ — that's this repo's own memory, it's the thing the human checks the
    proposal against, and it carries none of the flagged cross-repo/agent/abs-path
    detail, so the verbatim-citation rail (decision 8) is untouched. A body that
    still trips the classifier is trimmed further, never worked around — same
    propose/dispose deference the whole custodian holds. Sibling of decisions 15
    and 16: a run that finishes its work but can't ship its report is another
    half-done-looks-done failure, closed by making the shippable shape the default.

Refined 2026-07-27 by the custodian's own Phase E (issue #29, E-2 and E-1 adopted):

18. **Phase C gains a guardrail replay (the Sefz graft).** Sefz (arXiv
    2605.13044) translates a natural-language skill guardrail into "a
    reachability goal over an annotated execution trace, reducing violation
    checking to a deterministic graph query," and found violations in 120 of 402
    real skills using only benign inputs. `gates.jsonl` — rolled up cross-repo
    into `history-index.jsonl` — is exactly such a trace, so three of the loop's
    own guardrails now replay as `jq` predicates (`scripts/custodian-guardrails.sh`,
    wired into Phase C): **G1** no verdict without a run, **G2** the provenance
    lint reused **verbatim** from `state-schemas.md` (one source of truth, not a
    fork), **G3** no committed wave without an execution-evidence gate line — the
    informational cap-overflow item from the same #29 report, now mechanized.
    The legacy exemption is load-bearing, not cosmetic: pre-schema lines (no
    `verified_by` key) are reported EXEMPT, never violations — the validate-by
    replay over the 586-line index confirmed the naive form floods on the 387
    legacy lines, while the era-gated form is clean (G1 0 / G2 0 / G3 6, the six
    being genuine modern built-and-shipped waves whose gate lines recorded only
    `llm`/`null` verification, no `executable` — real findings, not false alarms).
    Get the exemption's provenance straight: `state-schemas.md`'s legacy note
    prescribes a _temporal, per-file_ exemption (a whole pre-schema `gates.jsonl`
    predates the fields and is exempt). This replay runs over the cross-repo
    `history-index.jsonl`, which _mixes eras line by line_, so it needs a per-_line_
    era test — this repo's own extension of that note, NOT something state-schemas.md
    prescribes; the script comment and the skill say exactly that rather than claiming
    prescription. Three design choices the replay forced: (a) G3's "committed wave" is
    **post-build activity** (crew / review / ship gate lines, or a commit-SHA named in
    a summary), NOT the index's `files` field — the indexer resolves `files` once per
    run, so it is branch-uniform and cannot tell which wave committed; keying G3 on it
    flagged pre-build-only gate waves that never shipped. (b) The replay is read-only
    digest signal, on the auto side of the propose/dispose line — it never edits, same
    as the rest of Phase C. (c) The era test keys on key-_absence_, so the ingest
    writer (`custodian-history.sh`) must copy `verified_by`/`outcome` into a record
    ONLY when the source line carried them. The original writer defaulted the key to
    `null` on every line, which silently erased the exemption on the next
    `history --rebuild`: the re-derived legacy lines came back WITH the key present,
    reclassifying all 387 modern and flooding false G2/G3 violations against an index
    the docs call "safe anytime" to rebuild. The writer now emits the two keys
    conditionally, so key-absence in the index mirrors key-absence in source and the
    exemption survives a rebuild. Faithful to Sefz's _pattern_ (trace-as-query);
    rejects a tool/store — pure `jq`, `[[no-third-party-hosted-tool-reliance]]`.
    Tested both directions: `scripts/custodian-guardrails.test.sh` proves each
    guardrail goes RED on a one-violation-per-guardrail fixture (exit 1 + the cite
    surfaces), that a clean fixture and a legacy line stay green, that a legacy source
    line pushed through the REAL ingest transform still classifies legacy/exempt after
    a rebuild while a modern `verified_by:null` line stays modern (null ≠ absent), and
    that G2 selects the same lines as `state-schemas.md`'s canonical provenance lint.

19. **Phase B gains a skill-spec lint (the Agent Skills schema port).** Phase E's
    rotating documentation-scheme track surfaced that the SKILL.md format is now a
    citable open standard (agentskills.io/specification, corroborated by the Claude
    Code skills docs): required `name`/`description`, exactly four optional fields
    (`license`/`compatibility`/`metadata`/`allowed-tools`), and a three-phase
    progressive-disclosure budget (~100-token discovery, <5000-token activation
    body, and on-demand `references/` files under a ~5000-token cap). Two indie
    linters publish concrete machine-checkable tables. Ported into
    `scripts/custodian-skill-lint.sh` — pure bash + awk + grep, no hosted tool —
    which Phase B now runs over the tracked `skills/` tree as a propose-only signal.
    Two tiers, deliberately split so the exit code carries only hard-spec breakage:
    **structural** (frontmatter allowlist, name pattern/length/dir-match, empty or
    over-length description, broken intra-skill links, reference nesting past one
    level — the link-chain half of which moved to advisory in decision 29,
    leaving the structural arm the FILE-depth half — a narrow secret-leak scan)
    exits 1 and can route a concrete finding to a `D-turncoat-<n>`;
    **advisory** (the token/line budgets) is INFO-only, never a
    violation, and informs _extraction_ (split a fat body into `references/`), never
    prose smoothing — the war-story prose is deliberate
    (`[[project-skill-slimming-yields]]`). Token counting is approximate (chars/4,
    the standard rough BPE proxy) and
    conservative in the flag direction: markdown/code-ish text tokenizes hotter than
    chars/4, so the proxy under-reports and anything it flags as over-budget is over
    for real — it only risks missing a marginal case, acceptable for an advisory that
    never gates. Two scoping choices keep it false-positive-averse: a _bare_ subdir
    path token in prose (`scripts/foo.sh`) is intra-skill only when the skill
    actually _bundles_ that subdir, else it's a repo-relative reference (out of
    scope, already covered by `validate-looper-config.sh`) — but an explicit
    markdown `](references/foo.md)` link is always validated, so a dangling target
    is a violation whether or not the subdir exists; and a `[[wiki-link]]` is validated only when the
    skill uses local wiki-links at all (≥1 slug resolves in-dir), so cross-scope
    memory `[[links]]` are never flagged. Description _edits_ are out of scope —
    findings only, human disposes. Validated E-1's `validate-by` by running it over
    all 13 skills today: **0 structural violations, 3 body-budget advisories**
    (`loop-de-looper`, `looper-custodian`, `looper-defend` over the ~5000-token soft
    ceiling — extraction candidates, not defects).
    `[[no-third-party-hosted-tool-reliance]]`: mine the check tables, not the
    linters. Both-directions test:
    `scripts/custodian-skill-lint.test.sh`. (Numbering note: decision 18 above,
    from the same issue #29 Phase E, is E-2's guardrail replay — landed via PR #31;
    this is 19.)

Refined 2026-07-28 by the custodian's own Phase E (issue #29, E-3 adopted):

20. **`looper-verify` gains a held-out composition check.** Phase E's SpecBench
    read ([arXiv 2605.21384](https://arxiv.org/abs/2605.21384)) found that "while
    every frontier agent saturates the visible suite, reward hacking persists" on
    held-out tests composing the same features — "all visible checks pass" is not a
    sufficient verify signal. So `looper-verify`'s executable-VF doctrine gains one
    new axis (not a sibling section): a held-out scenario whose defining property is
    INDEPENDENCE from the build's own visible tests, PRE-REGISTERED from the plan
    brief before build begins, parked verbatim, and run UNMODIFIED at verify —
    authoring it after the build, or editing it to pass, voids it. Blindness is named
    in two strengths: _procedural_ in a single executor context (same agent authored
    both, independence rests on pre-registration alone) and _structural_ in an
    orchestrated run (the orchestrator or a fresh dispatch authors it from the brief
    alone). Scoped to the same line the oracle rule draws — runtime-code waves with an
    executable oracle; doc/trivial waves exempt; ONE scenario per wave, not a parallel
    suite. Reporting is split: a held-out FAIL on a visible-green wave is a
    first-class verify failure on the normal fail path, never a footnote, and records
    `verified_by: executable` (the value PR #31's G3 guardrail checks with the
    `jq` predicate `.verified_by == "executable"`).
    `validate-by: shadow-run against E-1`. A fresh context authored a held-out
    scenario from E-1's brief-level contract ALONE — blind to
    `custodian-skill-lint.test.sh` — composing multiple structural classes plus an
    advisory against clean controls. E-1's visible suite is CI-green (PR #32
    `statusCheckRollup` SUCCESS, 2026-07-28); the held-out scenario passed all 9
    brief-contract assertions and surfaced three gaps the green suite did not
    fail on: (a) a broken intra-skill link was flagged only when a `references/`
    dir already existed — a link to `references/gone.md` in a skill with no
    `references/` dir exited 0; (b) the "one-level reference nesting"
    structural rule never fired — `references/a/b/c.md` exited 0, though the
    walker demonstrably reached depth-2 (a secret planted there was caught); (c)
    the same broken link was emitted twice, inflating the structural count (all
    three fixed in PR #32, `6afa4b3`). Recorded as findings for PR #32, not
    blockers here — and themselves the proof of the axis: a blind, brief-derived
    check caught what a green visible suite missed. (Numbering note: 18 = E-2
    guardrail replay (PR #31), 19 = E-1 skill-lint (PR #32), 20 = E-3 held-out
    verify (this); if they merge out of order, keep 18=guardrails, 19=skill-lint,
    20=held-out-verify.)

Refined 2026-07-28 from user feedback on the report issue (issue #29):

21. **Report checkboxes lead with plain language; detail follows.** The custodian's
    own report proposals read "like legal treatises or compiler manuals" — precise
    but unskimmable — so the report-issue spec gains a hard rule: every checkbox
    opens with a one-or-two-sentence plain-language explanation of what it is and why
    you'd tick it (no jargon, cite syntax, field names, or file paths), and the
    detailed technical body — verbatim evidence, failed relocation search, paths,
    `validate-by` — FOLLOWS that lead. The verbatim-citation rail (decision 8) is
    untouched: evidence is still quoted exactly, it just no longer opens the item. A
    concrete before/after `B-retire` template ships inline in
    `skills/looper-custodian/references/report-issue.md` so the
    headless cron has a shape to copy, and the same lead-with-plain rule extends to
    each phase section's intro and to the Phase B/E proposal-output lines. Sibling of
    decision 17: both close a legibility gap between "the work is correct" and "a
    human can act on it" — 17 for a public-repo classifier, this for a human reader.
    (Numbering note: decisions 18/19/20 are reserved by PRs #31/#32/#33 from the same
    issue #29 Phase E — 18 = E-2 guardrail replay, 19 = E-1 skill-lint, 20 = E-3
    held-out verify; this is 21. A same-anchor merge conflict with those siblings is
    expected and trivial — keep all five in order.)

Found 2026-07-29 during a `linklater` metadata-fetch bugfix run, root-caused live:

22. **Phase B now audits `memory: user` agent namespaces too, and gains a fifth
    condition (`B-migrate`).** A `the-looper` wave's hand-back claimed three memory
    writes; the orchestrator spot-checked its own project memory dir, found nothing,
    and (twice, across two separate incidents) wrongly recorded the writes as lost.
    Root cause: `the-looper`'s agent frontmatter carries `memory: user`, a harness
    feature giving it its own persistent, **cross-project** namespace at
    `~/.claude/agent-memory/the-looper/` (with its own `MEMORY.md` index) —
    completely separate from a project's `~/.claude/projects/<project>/memory/`
    that `looper-learn`'s save-table assumed was the only "Memory" destination. Both
    writes had actually landed; the orchestrator was checking the wrong directory.
    Considered and rejected a live sync/bridge between the two namespaces: agent
    memory is deliberately GLOBAL (no per-project subdir in its path) so a blind
    mirror would leak one project's facts (a dependency version, a security
    invariant) into every OTHER repo that agent touches, and vice versa pollute
    agent memory's cross-project craft lessons with one-off project noise. Fixed at
    two layers instead, same propose/dispose split the custodian already holds: (1)
    `looper-learn`'s "Save lessons at the right level" section gains an explicit
    save-time classification — cross-run craft → agent memory (default, no action);
    project-specific fact → project memory (explicit, won't appear otherwise); both
    → dual-write; (2) Phase B, the existing weekly safety net for exactly this shape
    of drift, now also enumerates every `memory: user` agent's namespace (glob
    `~/.claude/agents/*.md` frontmatter, once per run — global, not per-repo) in the
    same audit pass, and gains a fifth condition, **Misplaced**: an entry whose
    content reads as project-specific but sits in agent memory, or reads as
    agent-agnostic craft but sits in one project's memory. Propose-only like the
    other four conditions — `B-migrate` copies the entry to the correct namespace
    (with its own index line) and leaves a `[[breadcrumb]]` in the original, never
    deletes it, same non-destructive shape as `B-repoint` but across two namespaces
    instead of one file. No new governance model: `B-migrate` is a sixth checkbox
    tag in an existing propose-only phase, applied through the existing Phase D
    path.

Refined 2026-08-09 from the 2026-08-03 run's window burn:

23. **The usage-window gate moves to the run's front door, and Phase E's
    fan-out gets bounded by the headroom it just measured.** Decision 16
    put a probe in front of Phase E and stopped there, which left two holes
    the 2026-08-03 run walked straight through. (a) The probe gated only E,
    so a weekly tick landing in an already-hot window spent C/A/B before
    anything looked at the window. (b) Passing the gate was treated as
    permission for an unbounded dispatch. Read the log rather than the
    intuition: that run's pre-E probe recorded `five_hour` at 36% and
    dispatched — then `deep-research` fanned out 25 candidate claims, each
    drawing its own verifier panel, the window went dry, **all 25 panels
    errored**, and the phase reported 0 verified / 25 unverified. Phase E's
    discipline correctly refused to promote unverified claims to
    checkboxes, so the run spent its whole window to produce a digest with
    nothing actionable in it, and then hit the session limit at 09:49
    before Phase F. Three fixes, one threshold between them:
    - **Run-start gate.** The same `scripts/usage-window-probe.sh` and the
      same 95% default now run before Phase C. On the cron, the wrapper
      probes before it spends a headless session at all and waits out the
      reset (reusing the `wait_for_window_reset` the session-limit path
      already had) — except on a hot _weekly_ window, which cannot roll
      inside that helper's 6h cap and so defers immediately rather than
      burning the morning first. **Every unattended defer takes the loud
      path — notification plus a `Custodian INCOMPLETE <date>` issue —
      whether it came after the wait or straight away**, because a job
      that quietly does nothing is exactly the 2026-07-06 / 2026-07-13
      failure the alert paths were built for. The two differ only in what
      the issue body says happened. Invoked by hand, the run defers at
      step 0 with a breadcrumb and no issue, because a person is already
      watching. The breadcrumb names a fresh `/looper-custodian`, never
      `resume`: no phase logged means no tail to replay.
    - **Honest about what this gate does not cover.** It would NOT have
      saved 2026-08-03 — the front door was clear at 36%. Its case is the
      different one: a cron tick that never had room. Claiming otherwise
      would have made the incident look closed while the mechanism that
      caused it stayed live — and that mechanism turned out to have a
      second half, found later in the same log and recorded as decision 24.
    - **Fan-out bound.** The candidate count IS the fan-out width, because
      every candidate draws a verifier panel, and it is the only dial
      custodian holds — `deep-research` is invoked as a skill, and its
      internal execution cannot be batched, throttled, or interrupted
      mid-flight, which is why "check between batches" was considered and
      rejected as unimplementable from this side. So the bound is on the
      **ask**: a standing cap of 12 candidates across both tracks, shrunk
      by observed headroom (`1 − max(five_hour, weekly)`) to 6 below 0.60
      and 3 below 0.30, standing track only at either. Twelve is not a
      modelled rate — the one measurement is 25 candidates collapsing at
      0.64 headroom, and 12 is under half of a fan-out that demonstrably
      did not fit. Read that 0.64 for what it is, though: it was logged
      ahead of Phase B's 484-file fan-out rather than after it, so it is
      not shown to describe the quiet window a tier is meant to measure
      (decision 24). What did not fit still did not fit, so the cap
      stands — but it is anchored to a reading logged in an order the
      one-at-a-time rule now forbids. A second probe after E returns
      logs the real `utilization` delta, so the cap is replaced by
      measurement rather than left as a guess. `read_ok:false` keeps the
      standing cap unshrunk: unguarded means unsized, and treating an
      unread window as thin is the same fabrication as treating it as
      empty.
    - **A zero is never reported bare.** The failure that hurt most was not
      the collapse, it was that the collapse was invisible — a digest
      reading like a quiet week. Phase E now distinguishes three zeros and
      names which occurred: collapsed (panels errored, with counts and the
      window pct), empty (no candidate), unvalidatable (no `validate-by`).
      The report's E line carries it in the same shape as the existing
      deferred line.

    Tradeoff taken: this bounds an input, not an execution. If
    `deep-research` ignores the cap, or its verification fans out
    per-source rather than per candidate, the bound is weaker than it
    reads — which is precisely why the post-E measurement and the
    no-bare-zero rule are part of the same decision. They are what make a
    bound that failed visible, instead of another quiet zero. Unverifiable
    without a live cron run: the cap is applied inside the headless claude
    session and CI runs no session, so the first real Monday is the test.
    Not because the wrapper is unreachable — it takes `REPO`, `LOGDIR`,
    `WINDOW_PROBE` and `CUSTODIAN_PATH_PREFIX`, and
    `scripts/looper-custodian-cron.test.sh` drives its run-start gate end
    to end against a stubbed probe. What CI cannot stand up is the session
    the cap lives in.

24. **Phases run one at a time — a phase is done when its subagents have
    RETURNED, not when they were dispatched.** The same 2026-08-03 log that
    produced decision 23 also records the order that run LOGGED, and it is not
    the order the spec asserted. Its lines, in sequence: Phase B's
    skill-spec lint; then the pre-E usage-window probe, reading `five_hour
util 0.36 allowed, weekly util 0.11 allowed`; then `deep-research
dispatched (window healthy)`; and only THEN Phase B's `memory audit
fan-out dispatched (8 Read-only subagents)` over `files_total=484`, which
    logs full coverage afterwards. So the 36% that selected E's fan-out tier
    was read with an 8-subagent, 484-file fan-out still ahead of it. The order
    decision 16 leaned on as a substitute for a wave boundary was being
    satisfied at dispatch, not at return — and the log places no phase-B
    return ahead of that 36% reading. What that overlap cost in tokens is not
    knowable and is not claimed here: there is no per-phase accounting, and
    inventing one would be the fabricated gauge this design refuses everywhere
    else. The claim is the narrow one the log proves on its own — the
    asserted order is not the order that run logged, and the reading that
    sized E was logged ahead of Phase B's fan-out rather than after it.
    - **The rule.** Phases execute one at a time; no phase's fan-out may
      still be in flight when the next phase begins, and Phase E is probed
      and dispatched only after Phase B has fully returned. The order was
      always meant as a sequence to execute, not a sequence to start; it now
      says so. It binds the resume path too, and there it is a **correction,
      not a precaution**: the same 2026-08-03 run's resume tail did it again.
      That tail logs `E "usage-window re-probe (resume gate)"` and
      `E "E synthesized from killed run's reachable findings (no re-fan)"`
      before `B "staleness resolved against live tree (resume)"`. A tail
      holding both B and E runs B to completion before the pre-E probe. The
      tail looking small is why it happens, not a reason to write the clause
      as hypothetical.
    - **The alternative is unimplementable, not merely worse.** The other
      way to close this is to keep the interleave and have E's sizing
      subtract the cost of work still in flight. Be exact about what is
      missing, because this design already owns a per-phase instrument:
      decision 23's re-probe after `deep-research` returns logs
      `utilization` before → after, and bracketing a phase that way yields
      an OBSERVED cost for it. What has no observable is the **not-yet-spent
      concurrent cost at probe time**. The fan-out width is fixed in the
      research brief before `deep-research` is invoked, and its internal
      execution cannot be batched, throttled, or interrupted mid-flight, so
      there is no later moment at which a measurement could still change the
      ask — the sizing decision has to be made before the cost it would
      subtract exists. That number could only be invented, which is exactly
      the fake gauge `loop-de-looper`'s `## Budget governor` bans, and the
      mirror image of what Phase E's own `read_ok:false` rule already
      refuses in the other direction: treating an unread window as thin is
      the same fabrication as treating it as empty. So the concurrency is
      removed rather than estimated — the only one of the two that can be
      done honestly.
    - **A headroom tier is a reading of something specific.** The tiers in
      decision 23 describe the window as it stands with C/A/B complete and
      nothing else in flight. That is the whole of what a tier means, and it
      is why the digest's stated tier is only as true as this rule was kept.
    - **The archive says this is the run's shape, not a one-off drift.** The
      check flags 2026-07-27 and 2026-08-03, and none of the five logs before
      them. Per-log counts are deliberately not restated in this decision:
      they move with the check, and
      `scripts/custodian-phase-order.sh --date <date>` prints them for any log
      in `local/custodian/` on the machine that produced it — that dir is
      gitignored, so anywhere else the command exits 2 with `empty or missing
log` rather than a count. What prose owes is the shapes, since the check
      prints line numbers rather than a diagnosis. 2026-08-03 is the
      interleave twice over — once in its first segment,
      `E "usage-window probe (pre-E gate)"` and
      `E "deep-research dispatched (window healthy)"` ahead of
      `B "memory audit fan-out dispatched (8 Read-only subagents)"`, and again
      in its second segment, after the resume marker — the lines quoted higher
      up in this entry. 2026-07-27's first segment is the starkest case in
      the archive: an `E` probe, an `E` dispatch, and then a resume marker
      whose own line reads `session-limit kill at 09:29 left B unlogged + E
digest lost` — E dispatched, B never logged at all. Its second segment
      then does it again on the resume: `B "memory audit dispatched"`, then
      `E "deep-research re-dispatched from main session (run wf_6ef308bc-0c1)"`,
      and only then `B "audit complete — full coverage 36/36, 7 proposals"` —
      E dispatched while B was outstanding, dispatch read as done. Two
      consecutive runs is not a run that drifted once; it is the shape the run
      had settled into, and the rule is written against that.
    - **What the check asserts.** It reads B and E lines inside a segment
      and applies two predicates, reporting the shapes it cannot count as
      named classes instead. Both predicates, every class the report can
      print, and the exit contract are specified in
      `skills/looper-custodian/references/phase-order-check.md` — one home,
      so a token grepped out of a printed report lands somewhere that both
      defines it and is kept current.
    - **P2's discriminator is the earlier phase-B line, and it is decidable
      rather than heuristic.** P2 first read every no-B segment as a
      violation, which flagged 2026-07-27's fourth segment — a resume that
      legitimately had only E left, B having returned in segment 2. That was
      not an accepted cost, it was a defect, and `phase-order-check.md`
      carries the derivation: the check now asks whether a phase-B line
      exists earlier in the log, a question that file shows is decidable
      from the log rather than inferred. Measured over the eight archived
      logs, the discriminator reclassifies exactly one segment —
      2026-07-27's fourth, from violation to `RESUME TAIL` — while keeping
      2026-07-27's first flagged and leaving every other segment's verdict
      untouched, 2026-08-03's included.
    - **What the discriminator does NOT buy, stated plainly.** Three limits,
      each with its live archive precedent, in `phase-order-check.md`. They
      are accepted rather than closed, and none of them costs P2 what it
      exists for: the modal failure — E logged, B never logged, run then
      dead — cannot pass silently.
    - **The check runs at Phase F, which is past where both incidents died.**
      2026-08-03 hit the session limit at 09:49 before Phase F; 2026-07-27's
      log records a `session-limit kill at 09:29 left B unlogged + E digest
lost`. A run killed before F produces no verdict at all — the check's
      own output is one of the things the kill takes with it — and gets one
      only once a resume carries it to F. Both of these did reach F
      eventually, but on the far side of a resume: 2026-07-27's took a
      one-shot launchd job installed by hand, firing at 19:10 that evening.
      Be precise about who does the resuming, because the two kill shapes
      differ. The wrapper AUTO-resumes a session-limit kill — it waits out
      the window's reset and relaunches the resume path headless — while a
      ceiling-kill only breadcrumbs and waits for a human. So the window in
      which a broken Monday is invisible is "until the run is resumed",
      which on the ceiling path means until someone does it by hand, and a
      run nobody resumes is never checked. Named here for the reason decision
      23 names its own gap: an incident must not look closed while the
      mechanism that produced it stays live. The
      obvious place a partial-log check COULD run is the cron wrapper's
      INCOMPLETE path, which already renders `phases_summary()` over exactly
      that partial log before opening the issue. Considered and deferred, not
      overlooked: it is a change to the wrapper's alert path, and this
      decision is scoped to the ordering rule and its log check.

    Tradeoff taken: wall clock, and it is a real cost rather than a
    bookkeeping one. Phase E's `deep-research` runs as a harness-backgrounded
    workflow the CLI blocks for at end-of-turn, capped by
    `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`. Dispatching E early overlaps its
    runtime with Phase B's work, so less of it is left to wait out when the
    turn ends — very likely what the 2026-08-03 run was buying. Serializing
    gives that overlap up and pushes more of E's runtime inside the
    end-of-turn wait, which makes a ceiling-kill likelier. Accepted on one
    ground: a ceiling-kill is a detected, resumable state (decision 15),
    while a window reading that was already wrong when it was used leaves
    nothing to detect. Same caveat as decision 23, and for the same reason:
    nothing here can be exercised by CI, because what is being fixed is the
    runtime ordering of an unattended session against a real rate-limit
    window, so the first real Monday is the test. A check over
    `custodian-log.jsonl` asserting its phase lines land in order is worth
    having, and now exists — `scripts/custodian-phase-order.sh`, run by
    Phase F over the run's own log. But it tests the log, not the runtime. A
    run that dispatched out of order and logged in order would pass it, so a
    clean result is evidence of a well-ordered log and of nothing else. What
    it buys is timing — a broken Monday becomes visible that week rather
    than whenever someone next reads a log by hand. That is how both the
    2026-07-27 and the 2026-08-03 orderings sat unread until this decision
    was written: not one incident missed, but two consecutive weekly runs
    logging the same shape in plain text with nobody reading it.

25. **A check gated on passing is not gated on being able to fail.** Every
    suite in this repo asserts that its check goes green on a clean fixture
    and red on a dirty one. None asked the other question: if the rule it
    guards were broken, would the suite notice? `scripts/custodian-mutation-kill.sh`
    asks it, by planting declared mutants in a check and requiring the paired
    suite to go red on each. The first run found four fixture gaps in the
    guardrail replay: three mutations of G1's predicate (`or` to `and`, and
    dropping either side) and one of G2's second arm all left an
    18-assertion suite green, because a single fixture tripped every
    condition of a multi-condition `or` at once and so could not distinguish
    a working predicate from a broken one. G1 is the guardrail for
    loop-de-looper's hardest rule: no verdict without a run. Fixing it meant
    adding fixtures that separate the conditions, one at a time — and
    repeating that later for the recall check's six-alternative exclusion
    list and for G3's `committed_line`, both of which had the identical
    shape once a mutant looked.

    Mutants are DECLARED, never generated. A generator needs an
    equivalence oracle to know which mutants change behaviour at all, and an
    LLM standing in for that oracle is the say-so this framework refuses
    everywhere else; a hand-written operator mutant on a `jq` predicate
    needs no oracle, because the author asserts the change of meaning and a
    survivor is a fixture gap either way. **Not every survivor is a gap,
    though, and that had to be learned by shipping one.** Flipping `>` to
    `>=` on the phase-order line comparison survives and always will: line
    numbers are unique per record, so no input distinguishes the two forms.
    That mutant was dropped rather than left as a permanent red — a
    survivor is a finding only when some input can tell the forms apart.

    The harness's own false-green path is the one it guards hardest. A
    mutation whose pattern matches nothing leaves the file untouched, the
    suite passes, and a naive runner scores that as a kill. A first pass
    reported three such kills after its tree copy silently failed, so the
    harness now asserts the copy landed, requires the unmutated baseline to
    pass, reports DID NOT APPLY as a failure rather than a kill, and exits 2
    when no mutant ran at all. Two `perl` traps cost real time and are
    recorded beside the table: `\Q` suppresses metacharacters but not
    interpolation (and quotes a backslash, so escaping the sigil does not
    help), and `s///` without `/g` takes the first match in a slurped file,
    which in `custodian-guardrails.sh` is the comment quoting the predicate
    rather than the predicate.

26. **The order check can only interrogate lines that exist.**
    `scripts/custodian-phase-order.sh` asks whether the phase lines a run
    logged came in the order the run was meant to execute. A line the spec
    requires and nobody ever writes leaves no trace, so the log reads clean
    precisely because the obligation was skipped.
    `scripts/custodian-log-recall.sh` asks the complementary question, and
    found its own reason for existing on the first run:
    `skills/looper-custodian/references/usage-window-gates.md`
    requires a re-probe after `deep-research` returns, calls that logged
    line what turns the candidate cap "from a conservative guess into a
    calibrated number", and across nine archived runs the string appears
    zero times while five of them recorded deep-research returning. The
    number decision 23 calls calibrated has never had a measurement behind
    it.

    Two design choices carry the check. Triggers are declared in the script,
    not mined from the spec, because a regex inferring "when is this line
    due" would be a second spec rotting against the first — so a prescribed
    action string with no declared trigger exits 2, failing loudly at the
    moment the requirement is written rather than under-reporting forever.
    And the verdict vocabulary keeps three ways of not asserting a
    violation: SATISFIED, NOT EVALUABLE (never observed, but its trigger
    never fired either — a rule whose precondition never arose owes
    nothing), and UNDECLARED. Silence is not conformance, the same reason
    the order check spells `NOTHING CHECKED`.

    The spec is now a load-bearing input to a check that reads it, which
    bites in a way worth recording: writing the reference file for this
    check tripped it, because the prose quoted the prescribed-action form as
    an example and the harvest read the example as a real requirement.

27. **`verified_by` is written by the agent whose work it describes.** G3
    asserts that a committed wave carries a gate line whose `verified_by`
    equals `"executable"`, so the rule asks the audited agent to grade
    itself — and the field has drifted accordingly: across the cross-repo
    index it holds 17 distinct values, 419 `executable`, 156 `llm`, and 14
    one-off prose strings like `orchestrator, ran seed 555 twice`. Those 14
    counted as no-evidence, and a wave that simply types `executable` clears
    G3 whether a command ran or not. `hooks/record-execution-receipt.sh`
    records each shell execution to `local/loops/<branch>/receipts.jsonl`,
    which no agent authors, and `scripts/loop-receipts.sh` checks the claim
    against it from Phase A's kept-dir sweep.

    **What a receipt proves had to be corrected after review.** The first
    version read `.tool_response.exit_code`, a key the PostToolUse payload
    does not carry under any spelling — the real shape is `interrupted`,
    `isImage`, `noOutputExpected`, `stderr`, `stdout`, confirmed by dumping
    a live payload. All 159 real receipts recorded null, the check's clean
    arm was unreachable, and it fired a false VIOLATION on any branch with
    an `executable` claim. Its test passed because the fixture hand-wrote
    the key it then asserted on. That is decision 25's failure one layer up,
    in code written to prevent it, and it is why the fixtures now carry the
    payload the runtime actually sends and one asserts that no exit-code
    field is invented at all. What IS observable: the event fires on tool
    success — failures route to `PostToolUseFailure`, which nothing
    subscribes to — so a receipt's existence is the success signal and
    `interrupted` is the one qualifier.

    **G3 was deliberately not rewritten to read receipts.** Receipts begin
    when the hook is installed and every archived run predates them, so
    swapping the predicate would turn 419 historical lines into violations
    — the same flood the legacy `verified_by`-absent exemption exists to
    prevent. The receipts check is era-gated the same way: a branch with no
    receipts log is NOT EVALUABLE, never a violation, and the Phase A sweep
    never passes `--strict`. When receipts cover a meaningful span, G3 can
    retire into it.

    The command text is truncated to 200 characters with a digest beside
    it. Nothing reads the field — the check uses existence and `interrupted`
    — and storing it whole made the log a verbatim transcript of every shell
    command in the repo: 123KB of a 158KB log on one branch in one day.

28. **An advisory nobody can satisfy is not a guard.** The skill lint reports
    the published ~5000-token body budget as INFO. `looper-custodian` cannot
    reach it — a five-phase unattended cron spec is not a 5000-token
    document — so the finding was permanently present and permanently
    ignored, which is the recall-is-not-enforcement gap
    `scripts/correction-gates/README.md` names. The extraction in decision 27's
    branch proved both halves: `the-turncoat` took the body from 16451 to
    12430 tokens, and it drifted back to 13076 within the same session, one
    paragraph at a time, with every check green throughout.

    `scripts/skill-body-ceiling.sh` guards the property that was actually
    violated. Not "is this file small enough" — nobody believes it is — but
    "is it the size somebody last agreed to", recorded per skill in
    `scripts/skill-body-ceilings.tsv`. **Deliberately not a one-way ratchet.**
    The 646 tokens the Phase A receipts sweep added were worth adding, and a
    check that forbade them would be wrong; raising the ceiling in the same
    commit that grows the file is the mechanism, because the number then moves
    where a reviewer can see what it bought. The failure names both remedies —
    extract, or raise — so it cannot be read as an instruction to shrink.

    **The margin is derived, not round.** A ceiling set to the file's exact
    size fails on the next sentence anyone writes, which trains people to
    raise the number reflexively and turns the deliberate decision back into
    a formality. So the recorded ceiling carries roughly one mechanism's
    worth of slack, priced off the last real one — the Phase A receipts
    sweep cost 646 tokens across its paragraph, report line, roster entry and
    does-NOT line. One ordinary addition fits without ceremony; a second
    forces the extract-or-raise call, which is where the decision belongs.
    The slack note stays quiet at that size (it fires above a fifth of the
    ceiling), so a margin this size does not read as a ceiling that has
    stopped constraining anything.

    Two shapes it refuses to call clean, both learned from the checks written
    beside it: a ceilings file it cannot read (`-s` tests size, not
    readability, and a mode-000 file passes it while yielding no rows), and a
    file whose every line is a comment, which measures nothing and reports
    `NOTHING CHECKED` rather than success. Opt-in by design: a skill with no
    recorded row is not checked, so this governs the one spec that earned it
    rather than silently binding all eighteen.

Refined 2026-08-20 from the lint's own reference-nesting arm:

29. **A rule with two spellings and two answers is not a rule.** The skill
    lint's `reference-nesting` arm carried two unrelated checks under one
    name. One reads the filesystem: a reference file physically sitting at
    `references/a/b/c.md` is deeper than one level, and that is a path fact.
    The other read a cite inside a reference file and called it a chain —
    but it fed on `BARE_REF_RE`, which keys on a
    `references|scripts|assets|templates/` path SEGMENT. So the same chain
    got a different verdict depending on how someone typed it:
    `` `references/b.md` `` exited 1, `[b](b.md)` exited 1, and
    `` `b.md` `` was invisible.

    The evidence that it did not bind is `loop-de-looper`, the skill this
    spec was told to imitate. Its four reference files cite each other in
    eight places, every one spelled bare, and
    `custodian-skill-lint.sh skills/loop-de-looper` reported `structural
violations: 0`. Meanwhile this spec's own extraction was shaped around
    the rule as though it did bind — one paragraph stayed in `SKILL.md`
    only because moving it into a reference would have made that reference
    cite two siblings by qualified path.

    **Widened AND demoted, because widening alone makes the docs worse.**
    Fixing only the detection turns `loop-de-looper` red eight times, and
    the only route back to green is deleting eight legitimate pointers —
    `state-schemas.md` opens with "The governing rules live elsewhere",
    which is the pointer doing its job. A rule whose remedy is worse
    documentation is not measuring what it claims to.

    So the tier line already drawn in the linter's header decides it.
    Structural is what is decidable from the spec against the bytes; the
    advisory tier is what informs an EXTRACTION judgement. Nothing LOADS a
    reference file because a sibling names it, so a cross-link is a claim
    about how much a reader is being asked to carry — the same register as
    the token budgets. It becomes `adv-reference-chain`, INFO, exit 0. The
    FILE-depth half stays structural and is untouched.

    Detection widens so the tier means one thing. A new `BARE_FILE_RE`
    matches a bare filename with the same leading-delimiter guard
    `BARE_REF_RE` uses — the guard is what stops the TAIL of
    `skills/other/references/x.md` being re-read as a bare cite of a
    same-named local file — and both spellings resolve through one
    predicate, sibling-relative first, then from the skill root. Every
    spelling of one sibling cite now shares a verdict, and the shapes that
    are not chains — an upward cite, a self-cite, another skill's file —
    share silence. Both directions are pinned in
    `custodian-skill-lint.test.sh` by comparing whole finding SIGNATURES
    (exit code plus every finding as tier, check name and file) rather than
    a grep per spelling, so a case added later cannot agree vacuously.

    One narrowing rides along, and it is not incidental. A bare filename
    includes `SKILL.md`, so the arm is confined to targets inside
    `references/`: a cite pointing UP is depth zero. The old skill-root arm
    reported `[the body](SKILL.md)` from a reference file as a chain, and
    without the confinement the widening would have turned every reference
    file that mentions its own body into a finding.

    **What it costs, stated rather than buried.** Eight real cross-links in
    `loop-de-looper` become visible as five findings — `sort -u` collapses
    a cite repeated within one file — and nothing forces anyone to act on
    them, which is what advisory means. That is the trade: the arm stops
    being able to block, and starts being able to see.
