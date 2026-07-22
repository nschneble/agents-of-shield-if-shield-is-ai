# Looper Defend — design rationale + decision log

Status: **built.** Operational spec (the five phases, the adapter table, the
artifacts, the `apply` grammar, the full "what it does") lives in
`skills/looper-defend/SKILL.md` — that is the source of truth. This doc holds
only what the skill doesn't: *why* it exists, *why* the choices are what they
are, and the *decision record*. Don't duplicate mechanics here — if a phase's
behavior changes, it changes in `SKILL.md`.

## Why it exists

Two surfaces already touch security, and both answer the same question —
"is this CHANGE safe?":

- **`security-review`** (built-in) reviews the pending diff on the current
  branch.
- **`the-diamantaire`** carries security as one of its review dimensions, also
  over recently-modified code.

Both are reactive and diff-scoped. Nothing hunts the question "is this REPO
safe?" — a proactive pass over the whole tree, the reachable code paths, the
dependency manifests, the trust boundaries, and (where cheap) git history for
leaked secrets, independent of any pending change. A vulnerability that was
merged clean months ago, or that lives in a dependency nobody touched this
sprint, is invisible to a diff review precisely because there is no diff.

`looper-defend` is that proactive whole-repo hunt. It is deliberately NOT a
reimplementation of diff review — its triage phase MAY call `/security-review`
as one input signal for the pending-diff sub-case, but the hunt is the part
neither built-in covers. And it is the on-demand sibling of `looper-custodian`:
custodian housekeeps the looper *system* on a weekly cadence; defend hunts a
*target codebase* when a human asks.

## Governing principle: defend PROPOSES, human DISPOSES

The spine of the design, and the reason the phases split into auto vs gated.

An autonomous hunt that auto-rewrites application code to "fix" a suspected
vuln is exactly the "merging outpaces comprehension" failure the
loop-engineering sources warn about — and it is worse here than for a feature
wave, because a mis-triaged false positive "fixed" in app logic can introduce
the very defect it claimed to close. The reference harness draws the same line:
its patch ladder "verifies the crash is gone, not that the diff is safe to
upstream," so it surfaces the diff for a human rather than auto-applying. So:

- **Recon / find / triage / report run automatically** — read-only analysis, no
  source touched. They enumerate, hunt, verify, and rank.
- **Patch is propose-only** — every remediation lands as a checkbox in the
  report and proceeds through the build pipeline ONLY after a human ticks it.
- **One narrow class MAY auto-apply** — a dependency version bump to a pinned
  CVE-fix version, when the suite stays green with zero application-code change.
  Even it lands as a reviewable draft-PR commit: the human gates the MERGE, not
  the tick.

This is the same discipline the loop and custodian already hold. It is also the
`no-third-party-hosted-tool-reliance` posture applied to remediation: the loop
"stays self-contained… a rented hosted layer breaks that portability, adds an
auth/availability failure mode a headless cron can't clear." Defend never
auto-mutates app code behind a human's back for the same family reason custodian
never auto-edits a memory or an agent — the write is the thing that must be
comprehended before it lands, and defend is the propose-side of that split.

## Why these mechanisms (the non-obvious choices)

- **The reference harness's STRUCTURE was mined, its substrate was not.** Defend
  borrows Anthropic's `defending-code-reference-harness` shape — threat-model →
  scan → triage → patch — and, crucially, the `/customize` stack-abstraction
  idea: the harness ports across languages by answering "how is the target
  built? what signals a finding? how does it ingest untrusted input? what's the
  ground truth?" — **never by forking the pipeline per stack.** Defend adopts
  that as one agnostic pipeline with a runtime-detected adapter, rather than a
  JS fork and a Rails fork and a Python fork drifting apart. What it does NOT
  adopt is the harness's ASAN/Docker/gVisor substrate: that is a hard
  third-party isolation dependency this family forbids
  (`no-third-party-hosted-tool-reliance`). The adapter answers the three
  customize questions; the real scanners (`npm audit`, `bundler-audit`,
  `brakeman`, `pip-audit`, `govulncheck`, `semgrep`…) are optional,
  runtime-detected by `command -v`, never installed on the fly — the loop still
  runs on an LLM code read when none resolve.
- **The default surface is an interactive end-of-run report, not a GitHub
  issue.** This is the exact inverse of custodian's choice, and the difference
  is on-demand vs cron. Custodian opens an issue because it is an unattended
  weekly job with nobody watching and `local/` is gitignored — a local report
  would be invisible at write time and unreachable by a later `apply`. Defend is
  on-demand and interactive: the human who invoked it is present to read the
  report inline (like `loop-de-looper`'s exit report), plus a persisted
  `local/defend/<run-id>/report.md` that `apply` reads back for the ticked
  boxes. A GitHub issue is opt-in (`--issue`) for a shared/CI context that wants
  a tracked, persistent notification — and on a public target it inherits
  custodian's sanitization discipline.
- **The auto-patch carve-out is dep-bump-only, and even it stays reviewable.**
  The only class that skips the tick is a dependency bump to a pinned CVE-fix
  version with a mechanical verifier (the suite) and zero app-code change. The
  narrowness is deliberate: a dep bump has a ground-truth oracle (the lockfile
  pins the fix version, the suite proves nothing broke) that a logic fix does
  not, so it is the one class where "auto" doesn't mean "unverified." But it is
  still not "auto" all the way to merge — it lands as a draft-PR commit through
  the same `looper-plan`/`build`/`verify`/`review`/`commit` chain, so the PR
  diff is the preview and the human gates the merge. Skipping review entirely
  was rejected: the propose/dispose line moves to the merge, it does not
  disappear. (And in the zero-scanner LLM-read mode there is no mechanical
  verifier at all, so *nothing* is auto-eligible — every finding is
  propose-only.)
- **v1 excludes PoC-execution and fuzzing; the executable tier is
  assertion-style.** Defend's executable oracle never fires a crafted payload at
  a sink. For an injection / SSRF / path-traversal class the repro asserts the
  *fix invariant* — "the query is parameterized" (CWE-89), "the path is
  canonicalized and confined" (CWE-22), "the outbound URL is validated against
  the allowlist" (CWE-918) — or runs a controlled benign probe, never a
  weaponized malformed input. This is the deliberate divergence from the
  harness's exploit-crafting agents, which DO fire crafted payloads and
  therefore NEED the sandbox defend forgoes. By never executing untrusted input
  in any phase, defend carries no isolation requirement at all — which is what
  lets it run as plain-markdown skills over local state instead of demanding a
  gVisor/Docker substrate. An adapter that ever executed a PoC would need that
  isolation and is explicitly out of v1 scope. (This exclusion was not obvious
  up front — it is the contradiction the crew caught and the corrective wave
  resolved; see decision 2.)

## Decision log

Built 2026-07-21 (wave 1, commit `fdb1e44`):

1. **Initial build — five read-mostly phases, an agnostic adapter, propose-only
   by default.** The skill shipped as recon → find → triage → report → patch,
   with recon/find/triage/report read-only and patch gated. Three shaping
   decisions:
   - **One agnostic pipeline with a runtime-detected adapter, NOT a per-stack
     fork.** Mined from the reference harness's `/customize` (ports across
     languages by re-answering the build/finding/input/ground-truth questions,
     never by forking) — a JS fork + a Rails fork would drift; one pipeline with
     a stack adapter does not. Rationale above.
   - **Propose-only default with one narrow auto-class.** Patch writes nothing
     without a ticked `P-<n>` + explicit `apply`, mirroring custodian's
     `apply #<id>`. The sole exception is the dep-bump-to-pinned-CVE-fix class,
     and even it lands as a reviewable draft-PR commit.
   - **Interactive end-of-run report as the default surface, issue opt-in.** The
     on-demand-vs-cron inverse of custodian's issue-by-default. Rationale above.

2. **Crew-blocker refinement (wave 1, corrective commit `a67d066`).** The first
   crew pass (the-stickler + the-diamantaire) surfaced two real blockers,
   resolved against each cited dependency skill:
   - **Pipeline gap.** The draft shortcut the remediation path — it did not
     route every fix through the full canonical chain, so a single-finding fix
     could skip the plan and review passes that `looper-build` and
     `looper-commit` actually require. `looper-build` STOPs without a
     `looper-plan` brief that names a rung, and `looper-commit`'s pre-flight
     will not land a fix without a `looper-review` verdict. Resolved: patch now
     names the full `looper-plan → looper-build → looper-verify → looper-review
     → looper-commit` chain at every call site and runs a real (if short) plan
     and review pass even for a one-line fix — the wave is small, the pipeline
     is not skipped.
   - **Oracle contradiction.** The draft's executable-oracle language
     contradicted its own "no execution of untrusted input" safety rail — it
     read, in places, as if triage/patch fired a repro exploit, which would have
     demanded the very sandbox defend claims to forgo. Resolved in the
     "assert the fix invariant" direction: triage's executable tier and patch's
     verification are assertion-style (query parameterized, path canonicalized,
     URL allowlisted) or a controlled benign probe, never a crafted payload —
     made consistent across triage, the patch ladder, the safety rails, and the
     does-NOT-do list. This is exactly the kind of "why" this doc exists to
     hold: the exclusion of PoC-execution is a deliberate scope line, not an
     oversight.

   The same corrective commit also introduced the **auth/authz ESCALATE
   handling** — an authz finding's remediation wave emits plan's `ESCALATE:
   security-review` and defend routes it the normal way (hand to the
   orchestrator, fire the specialist, resume at build) rather than swallowing
   it. Decision 3 below later tightens that claim from "always escalates" to the
   two-case shape, so the reader meets it here first.

3. **W3 + phrasing tightening (wave 2, this doc's wave).** A diamantaire
   re-review (both original blockers confirmed fixed) found one remaining real
   gap plus two phrasing overreaches, closed alongside these docs:
   - **The auto-patch carve-out now halts on app-code diffs FOR REAL.** The
     "diff confined to the manifest/lockfile" condition was classified at
     triage-time — before any fix existed — and never re-checked against the
     actual diff `looper-build` produces. The Patch section now specifies a hard
     mechanical gate: after build, before commit, `git diff --name-only HEAD` is
     checked against the adapter's manifest+lockfile path pair; any path outside
     it demotes the finding to propose-only (a normal ticked `P-<n>`) instead of
     auto-committing. The triage flag was a prediction; this is the enforcement.
   - **The auth/authz ESCALATE claim was tightened.** The draft overstated that
     any auth/permission/token finding definitely trips plan's escalation.
     `looper-plan`'s actual trigger is narrower — a *public API contract change*
     — which a fix that tightens an existing check without changing its
     signature need not hit, and `looper-build`'s security-review row fires only
     when plan already escalated (it is not an independent build-time mandate).
     Reworded to the two-case shape: a contract-changing fix routes the normal
     `ESCALATE` flow; a check-tightening fix that plan doesn't escalate on its
     own is noted in the report for human awareness rather than having defend
     manufacture a gate the cited dependency doesn't require.
   - **The `looper-commit` pre-flight citation was corrected** to attribute the
     review-verdict requirement to pre-flight item 2 (item 1 is the separate
     `looper-verify` PASS), rather than crediting both items to the one claim.
