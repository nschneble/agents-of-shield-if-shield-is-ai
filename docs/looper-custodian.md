# Looper Custodian — design rationale + decision log

Status: **built.** Operational spec (phases, artifacts, scheduling, the full
"what it does") lives in `skills/looper-custodian/SKILL.md` — that is the source
of truth. This doc holds only what the skill doesn't: *why* it exists, *why* the
choices are what they are, and the *decision record*. Don't duplicate mechanics
here — if a phase's behavior changes, it changes in `SKILL.md`.

## Why it exists

The looper system learns and tidies *per run*: `looper-learn` writes lessons at
the end of each wave and orchestration; `the-turncoat` streamlines an agent or
skill when asked. Nothing runs *across* runs and *across* repos on a cadence.
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
   ambiguous on whether a leftover *local* branch blocks reaping. It doesn't — a
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
   propose/dispose split already gated *commitment*; this makes the committed
   step approve a *previewed* diff and a regretted one revert in one command.
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
    returns ranked *cited* matches (~50× token-efficient vs a raw scan) with a
    `--file` filter. `gates.jsonl` is already our structured session log, so the
    graft is *retrieval, not a new store*: Phase C now maintains
    `local/custodian/history-index.jsonl` (append-only, one record per gate line
    + `repo`/`branch`/`files`/`cite`), ingests only new runs each week instead of
    re-scanning all history, and a read-only `history <query>` verb serves ranked
    cited lookups (incl. `--file`, re-created from git). Faithful to ctx's
    *pattern*; rejects its *substrate* — no Rust binary, no SQLite. That is the
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
    GONE). Resolution is existence-plus-`grep` against the *right* root
    (user-global vs repo), never exact-line — line drift (`:42`→`:47`) is not a
    dead reference, and a moved target is a re-point, not a retire (the same
    "provably gone, not merely moved" line `loop-de-looper`'s stale-candidate
    pre-check draws). A retire on a dead cite carries the failed relocation
    search quoted verbatim, so the human verifies *gone* not merely *moved* — a
    sibling of the "no delete on contradiction alone" rail. Faithful to
    capn-hook's *pattern* (hash-invalidation of code-citing recalls); rejects its
    *substrate* — no `.capn/` store, no SQLite, just a path check over the memory
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

15. **Phase E gets ceiling headroom, and a ceiling-kill is resumable, not
    silently dropped.** The 2026-07-20 run backgrounded Phase E's `deep-research`
    and then hit the harness `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` default
    (600s) while the fan-out was still running (~644s in, not yet done). The
    harness terminated the workflow — but a ceiling-kill still exits 0, so the
    wrapper counted it a clean success: no `Custodian report` issue was ever
    opened and ~1.4M tokens of already-completed research were thrown away with
    no trace but a drained session limit. Sibling failure mode to decision 13's
    silent-on-failure wrapper — a half-done run that *looks* done is as bad as a
    dead one that looks alive. Three fixes: (a) the wrapper raises the ceiling to
    30 min so a normal Phase E finishes within the end-of-turn wait and Phase F
    runs; (b) a ceiling-kill is detected (the harness'
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
    The custodian has no wave loop, but the C → A → B → E order is itself a
    checkpoint and E is the dispatch worth gating. So E now runs
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
    only what a human needs to *approve a checkbox*: Phase A/C give counts + a
    repo-agnostic gloss (exact `repo/branch:line` cites stay in the log), crew
    agents are named by role not code name, and memories/skills are named by bare
    slug not filesystem path. What stays verbatim is Phase B's quoted memory
    *evidence* — that's this repo's own memory, it's the thing the human checks the
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
    prescribes a *temporal, per-file* exemption (a whole pre-schema `gates.jsonl`
    predates the fields and is exempt). This replay runs over the cross-repo
    `history-index.jsonl`, which *mixes eras line by line*, so it needs a per-*line*
    era test — this repo's own extension of that note, NOT something state-schemas.md
    prescribes; the script comment and the skill say exactly that rather than claiming
    prescription. Three design choices the replay forced: (a) G3's "committed wave" is
    **post-build activity** (crew / review / ship gate lines, or a commit-SHA named in
    a summary), NOT the index's `files` field — the indexer resolves `files` once per
    run, so it is branch-uniform and cannot tell which wave committed; keying G3 on it
    flagged pre-build-only gate waves that never shipped. (b) The replay is read-only
    digest signal, on the auto side of the propose/dispose line — it never edits, same
    as the rest of Phase C. (c) The era test keys on key-*absence*, so the ingest
    writer (`custodian-history.sh`) must copy `verified_by`/`outcome` into a record
    ONLY when the source line carried them. The original writer defaulted the key to
    `null` on every line, which silently erased the exemption on the next
    `history --rebuild`: the re-derived legacy lines came back WITH the key present,
    reclassifying all 387 modern and flooding false G2/G3 violations against an index
    the docs call "safe anytime" to rebuild. The writer now emits the two keys
    conditionally, so key-absence in the index mirrors key-absence in source and the
    exemption survives a rebuild. Faithful to Sefz's *pattern* (trace-as-query);
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
    level, a narrow secret-leak scan) exits 1 and can route a concrete finding to a
    `D-turncoat-<n>`; **advisory** (the token/line budgets) is INFO-only, never a
    violation, and informs *extraction* (split a fat body into `references/`), never
    prose smoothing — the war-story prose is deliberate
    (`[[project-skill-slimming-yields]]`). Token counting is approximate (chars/4,
    the standard rough BPE proxy) and
    conservative in the flag direction: markdown/code-ish text tokenizes hotter than
    chars/4, so the proxy under-reports and anything it flags as over-budget is over
    for real — it only risks missing a marginal case, acceptable for an advisory that
    never gates. Two scoping choices keep it false-positive-averse: a *bare* subdir
    path token in prose (`scripts/foo.sh`) is intra-skill only when the skill
    actually *bundles* that subdir, else it's a repo-relative reference (out of
    scope, already covered by `validate-looper-config.sh`) — but an explicit
    markdown `](references/foo.md)` link is always validated, so a dangling target
    is a violation whether or not the subdir exists; and a `[[wiki-link]]` is validated only when the
    skill uses local wiki-links at all (≥1 slug resolves in-dir), so cross-scope
    memory `[[links]]` are never flagged. Description *edits* are out of scope —
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
    in two strengths: *procedural* in a single executor context (same agent authored
    both, independence rests on pre-registration alone) and *structural* in an
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
    concrete before/after `B-retire` template ships inline in `SKILL.md` so the
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
