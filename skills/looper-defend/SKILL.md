---
name: looper-defend
description: On-demand autonomous vulnerability hunt + remediation over a whole repo. Five phases — recon → find → triage → report → patch. Proactive whole-tree/whole-history hunt (the part `security-review` and `the-diamantaire` don't cover: they review the pending diff, this hunts the codebase). Findings surface as a structured end-of-run report with checkbox patch proposals; a patch proceeds only after a human ticks it (mirroring custodian's `apply #<id>`), routing through the normal `looper-build` → `looper-verify` → `looper-commit` pipeline — never a bespoke fixer. Real scanners (npm audit, bundler-audit, brakeman, pip-audit, govulncheck, semgrep…) are OPTIONAL, runtime-detected adapters; the loop still runs on an LLM code read when none are installed. Trigger when the user says "find and fix bugs", "find and fix vulnerabilities", "security scan this repo", "hunt for vulns", or "run looper-defend". Not cron — on-demand only.
---

Proactive whole-repo vulnerability hunt + human-gated remediation. `looper-custodian` GCs and audits the looper system on a cadence; `looper-defend` hunts a TARGET codebase for security defects on demand. Structure mined from Anthropic's `defending-code-reference-harness` (threat-model → scan → triage → patch, plus its `/customize` stack-abstraction) — the STRUCTURE, not its ASAN/Docker/gVisor substrate, which is a hard third-party dependency this family forbids (`[[no-third-party-hosted-tool-reliance]]`).

Full design rationale + decision log: `docs/looper-defend.md` (added wave 2). This file is the executable spec.

## Why this exists — and how it differs from what already reviews security

Three surfaces already touch security; defend is the one they leave uncovered:

- **`security-review`** (built-in) and **`the-diamantaire`** (security is one of its review dimensions) both review the **pending diff on the current branch** — reactive, change-scoped. They answer "is this CHANGE safe?"
- **`looper-defend`** answers "is this REPO safe?" — a proactive hunt over the whole tree (and, where cheap, git history for leaked secrets), reachable code paths, dependency manifests, and trust boundaries, independent of any pending change.

Defend does NOT reimplement diff review: its triage phase MAY invoke `/security-review` as ONE input signal for the pending-diff sub-case, but the hunt is the whole-repo part neither covers. And it does NOT reinvent a patcher — remediation routes through `looper-build` → `looper-verify` → `looper-commit`, the same pipeline every wave uses.

## Governing principle: defend PROPOSES, human DISPOSES

Same discipline the loop and custodian hold. An autonomous hunt that auto-rewrites application code to "fix" a suspected vuln is exactly the "merging outpaces comprehension" failure the loop-engineering sources warn about — and a mis-triaged false positive "fixed" in app logic can introduce the very bug it claimed to close. The reference harness draws the same line: its patch ladder "verifies the crash is gone, not that the diff is safe to upstream," so it surfaces the diff for human review rather than auto-applying. So:

- **Recon / find / triage / report run automatically** — read-only analysis, no source touched. They enumerate, hunt, verify, and rank.
- **Patch is propose-only by default** — every remediation lands as a checkbox in the report and proceeds through the build pipeline ONLY after a human ticks it.
- **One narrow class MAY auto-apply** — a dependency version bump to a pinned CVE-fix version, when the existing suite stays green with ZERO application-code change (diff confined to the manifest/lockfile). It still lands as a reviewable **draft-PR commit** through `looper-build`/`verify`/`commit` — the human gates the MERGE, not the tick. Any condition unmet (no pinned fix version, suite red, diff touches app code) demotes it to propose-only. Everything else — any logic change, any fix touching application code — needs the tick.

## Invocation

Noun-verb grammar (`docs/looper-skills.md` → `## Subcommand grammar`), same shape as custodian:

| Invocation | Does |
| ---------- | ---- |
| `/looper-defend` (or an NL trigger) | the **hunt run**: phases recon → find → triage → report, read-only, ends by emitting the structured report + persisting findings |
| `/looper-defend apply #<finding-id>` | **patch one finding**: builds a wave brief for that finding and routes it through `looper-build` → `looper-verify` → `looper-commit` |
| `/looper-defend apply <run-id>` | **patch all ticked findings** in that run's report, idempotently, each as its own wave |
| `/looper-defend apply #<finding-id> --dry-run` | **preview**: prints the proposed patch brief + the exact diff the fix would attempt, and writes nothing. Consent approves a *previewed* fix, not a *described* one |

`apply` is the verb, `#<finding-id>`/`<run-id>` the arg, `--dry-run` the flag — the exact interaction model custodian uses, not a new grammar. Patch phase writes nothing without an `apply` (except the narrow auto-class above). There is no bespoke `undo`: remediation lands as git commits on a **draft PR**, so the PR diff IS the preview and `git`/PR-close IS the reversal — reusing the pipeline's own review+revert path rather than reinventing custodian's snapshot/undo.

## Stack detection + adapter table (platform-agnostic v1)

ONE agnostic pipeline, stack plugged in as a runtime-detected adapter — the same design the harness's `/customize` skill uses (it ports across languages by answering "how is the target built? what signals a finding? how does it ingest untrusted input? what's the ground truth?" — never by forking the pipeline). Recon detects the stack by manifest marker and selects the adapter; the phases are stack-invariant.

An adapter answers three questions, none of which is a hard dependency:

| Stack marker | Optional scanners (runtime-detected, NEVER required) | Verify/build oracle | Auto-patch-eligible class |
| ------------ | ---------------------------------------------------- | ------------------- | ------------------------- |
| `package.json` (Node/JS/TS) | `npm audit` / `osv-scanner` / eslint security plugins, if installed | `npm test`, `npm run build` | `package-lock.json` CVE bump |
| `Gemfile` (Ruby/Rails) | `bundler-audit` / `brakeman`, if installed | `bundle exec rspec` / `rake test` | `Gemfile.lock` CVE bump |
| `pyproject.toml` / `requirements.txt` (Python) | `pip-audit` / `bandit`, if installed | `pytest` | pinned-dep CVE bump |
| `go.mod` (Go) | `govulncheck`, if installed | `go test ./...` | `go.sum` CVE bump |
| any / cross-cutting | `semgrep`, `gitleaks`/`trufflehog` (secret scan), if installed | project's declared test command | — |
| none matched, or no scanner installed | — (LLM code read only) | project's declared test command, if any | none (no mechanical dep-bump oracle) |

- **Detection is by presence, not by network call.** A scanner is used ONLY if the binary resolves on `PATH` (`command -v`); absent ⇒ skipped, logged, never installed on the fly.
- **The loop still runs with zero scanners** — recon + find fall back to an LLM-driven code read (narrower recall, no execution-verified tier). In that mode NOTHING is auto-patch-eligible: with no mechanical verifier for a dep bump, every finding is propose-only.
- **Adapters compose.** A monorepo with both `package.json` and `Gemfile` selects both; a polyglot repo runs each matched adapter's optional scanners and one shared LLM code read.

## The five phases

Run in order. Each logs to `local/defend/<run-id>/findings.jsonl` before the report is emitted. Recon/find/triage/report are read-only; only patch (via `apply`) writes.

### Recon — scope + threat model + partition (read-only)

- **Detect the stack(s)** by manifest marker; select adapter(s) and probe which optional scanners resolve on `PATH`. Log the adapter set and the available-scanner set.
- **Build a lightweight threat model** — attack-surface boundaries, untrusted-input entry points (HTTP handlers, deserializers, file/CLI parsers, template rendering), authn/authz surfaces, secret-handling paths, and the dependency inventory. This scopes the hunt and is the primary false-positive suppressor (a finding outside the trust boundary is noise). Analogous to the harness's `THREAT_MODEL.md` checkpoint.
- **Partition the repo into hunt surfaces** — distinct subsystems (per adapter, per trust boundary) so find can explore them without converging on the same defect. Mirrors the harness's recon-partition strategy.
- Output: a threat-model + surface list held in the run dir. No source touched.

### Find — hunt each surface (read-only)

Per surface, gather **raw candidates** from two tiers, each tagged with its provenance:

- **Executable tier** (`verified_by: executable` when it fires) — run each available optional scanner scoped to the surface; a scanner hit with a CVE/CWE id is an execution-verified candidate. Dependency-manifest audit (`npm audit` et al.) lands here.
- **Judgment tier** (`verified_by: llm`) — an LLM code read of the surface for the standard classes: injection (SQL/command/template), unsafe deserialization, path traversal, SSRF, missing-authz / broken access control, hardcoded secrets, unsafe-eval, weak crypto, and dependency risk the audit tool missed. Each candidate MUST cite a concrete `file:line` and a plausible reachability path from an untrusted entry point — an uncited "this looks risky" is not a candidate.

Find produces candidates only; it does NOT rank, dedupe, or decide real-vs-noise — that is triage's job. A candidate with no runnable oracle stays a candidate, never silently promoted.

### Triage — verify, dedupe, rank, classify (read-only)

The real-vs-noise gate. For each candidate:

- **Promote candidate → finding** only when confirmed:
  - an **executable oracle** confirmed it (a scanner hit with an id, or a written repro/failing test that reproduces the defect) → `verified_by: executable`, `outcome: promote`; OR
  - for a class with no runnable oracle, the LLM read is **corroborated** by a second signal (a matching CWE pattern, a reachable data-flow traced end-to-end from an untrusted entry point) AND cited to `file:line` with the exploit path → `verified_by: llm`, `outcome: promote`.
  - A candidate that survives neither is **refuted** (`outcome: refute`) and demoted to informational — reported as noise-suspect, never a patch proposal. Borrows `the-diamantaire`'s refute-or-promote posture and the family's `verified_by` split.
- **False-positive filters** (mirror the harness's triage): drop findings in **test/fixture code**, findings on **unreachable paths**, and defects that are an **upstream library's responsibility** (report as a dependency finding, not an app-code finding).
- **Dedupe by root cause, not by line** — group candidates by the underlying defect (same sink reached from two call sites is ONE finding). Dedupe within the run AND against prior runs' `findings.jsonl` in `local/defend/` (key on function/sink identity, not line number, which drifts).
- **Severity + exploitability** — rate each finding on the harness's dimensions: primitive class (what kind of defect), reachability (accessible from untrusted input?), escalation path (impact if triggered), and constraints. Assign `critical | high | medium | low | info` on that judged rubric (not a keyword scan); carry a CWE/CVE id where one is known. This is not a novel scheme — standard severity mapped to exploitability, no CVSS-tooling dependency.
- **Classify remediation** per finding: `auto-patch-eligible` (the narrow dep-bump class only) vs `propose-only` (everything else).

### Report — surface findings (read-only)

**Surface: an end-of-run structured report to the user, NOT a GitHub issue per run.** Custodian opens an issue because it is an unattended cron with nobody watching and `local/` is gitignored; defend is **on-demand and interactive** — the user is present to read the report inline. So the default is a structured report emitted to the user (like `loop-de-looper`'s exit report), plus a persisted `local/defend/<run-id>/report.md` carrying the tickable patch proposals that `apply` reads back. A GitHub issue is **opt-in** (`--issue`) for a shared/CI context where a tracked, persistent notification is wanted; when a target repo is public, the same sanitization discipline as custodian applies (`[[looper-custodian]]` report rules).

- Report body groups findings by severity, each with: id, `file:line`, primitive class + CWE/CVE, reachability/exploitability one-liner, `verified_by`, and the proposed remediation.
- **Each actionable remediation is a checkbox** tagged `P-<n>` (patch proposal), verbatim evidence inline — the exact checkbox-and-`apply` model custodian uses (`B-merge-<n>` → tick → `apply`).
- Informational (refuted / noise-suspect / upstream) findings are listed WITHOUT checkboxes — signal for the human, not a tick-to-apply box.
- **No findings → no report noise.** A clean hunt says so in one line and opens nothing.
- To remediate: tick the `P-<n>` boxes and run `/looper-defend apply <run-id>` (or `apply #<finding-id>` for one).

### Patch — remediate through the normal pipeline (gated)

Triggered by `apply` (or auto, for the narrow dep-bump class). Defend does NOT patch directly — it constructs a **wave brief** per finding and routes it through the standard pipeline. For each ticked `P-<n>`:

1. **Build the wave brief** `looper-build` consumes (via `looper-plan`'s brief shape):
   - `scope`: "remediate finding `<id>`: `<class>` at `<file:line>`" — the smallest change that closes the vuln, nothing beyond.
   - `constraints`: fix must not change behavior beyond closing the defect; existing suite stays green; smallest blast radius (`looper-build`'s rung discipline).
   - `target`: the branch/PR the run is landing on; `pr`/`push` directives per `looper-commit`.
   - `exit criteria`: the finding's repro no longer triggers AND the suite stays green — defend's analog of the harness patch ladder (T0 applies+builds → T1 repro stops → T2 suite passes → optional T3 re-hunt the surface can't re-find it).
2. **Route it**: `looper-build` (smallest change) → `looper-verify` (confirm repro gone + suite green; the executable completion gate where a repro oracle exists) → `looper-commit` (lands the fix on the draft PR). In a `loop-de-looper` context, hand each as a queued wave to the orchestrator's `the-looper` dispatch instead of invoking the skills directly.
3. **Idempotent** — a finding whose fix is already present is a no-op, never a double-patch. Re-running `apply` on the same run is safe.
4. **Honor tool availability** — if defend cannot actually invoke `looper-build`/`looper-verify`/`looper-commit` (no Skill/Task tool), it logs `ran: false` and hands the constructed briefs back for the user/orchestrator to run — NEVER a claimed-but-unrun patch. Same `task_tool_available: false ⇒ ran: false` discipline as custodian.

The narrow auto-patch-eligible class runs steps 1–2 without waiting for a tick, then reports every auto-applied bump explicitly in the run report so the present human sees it — landing as a draft-PR commit, reversible.

## Artifacts + findings log

Under `local/defend/<run-id>/` (gitignored, same status as `local/loops/` and `local/custodian/`):

- **`findings.jsonl`** — append-only, one record per finding, never rewritten. The machine record; the report's claims trace to it.
- **`report.md`** — the human-review + `apply` surface: the structured report with `P-<n>` checkboxes. Read back by `apply` to parse ticked boxes (checkboxes only — no free-text approval parsing, same as custodian).
- **`threat-model.md`** — recon's scoping checkpoint, so a re-run or a resumed patch phase reuses the scope rather than re-deriving it.

`findings.jsonl` record — one line per finding, analogous to `gates.jsonl`:

```json
{
  "finding_id": "F-3",
  "phase": "triage",                 // "recon" | "find" | "triage" | "report" | "patch"
  "severity": "high",                // critical | high | medium | low | info
  "primitive": "sql-injection",
  "cwe": "CWE-89",
  "location": "src/api/users.ts:142",
  "reachable_from": "POST /users/search (untrusted query param)",
  "task_tool_available": true,       // false = could NOT invoke a scanner/sub-skill
  "ran": true,                       // false when a needed tool was unavailable
  "verdict": "reachable SQLi via unparameterized query",
  "outcome": "promote",              // "promote" | "refute" (real-vs-noise), else null
  "verified_by": "llm",              // "executable" | "llm" | null (null when ran:false)
  "remediation": "P-2",              // proposal tag, or null for informational
  "auto_eligible": false
}
```

- **`verified_by: executable`** only when a scanner hit or a runnable repro backed the verdict; a cited code-read judgment is `verified_by: llm` — never dressed up as a check that never ran. `null` only when `ran: false`.
- **`outcome`** is `promote`/`refute` for the triage real-vs-noise decision; `null` on a bare recon/find enumeration record.
- **`task_tool_available: false ⇒ ran: false ⇒ no invented outcome`** — a scanner or sub-skill defend could not invoke is logged unavailable, never as a passed check with a fabricated finding.

## Safety rails

- **Propose-vs-dispose split is the spine** — recon/find/triage/report read-only auto; patch gated behind a ticked `P-<n>` + explicit `apply`. Only the narrow dep-bump class auto-proceeds, and even it lands as a reviewable draft-PR commit.
- **Patch routes through the normal pipeline** — `looper-build` → `looper-verify` → `looper-commit`, never a bespoke fixer; the PR diff is the preview, git/PR-close the reversal.
- **Real scanners are optional, runtime-detected** — never a hard dependency, never installed on the fly; the loop runs on an LLM code read when none resolve (`[[no-third-party-hosted-tool-reliance]]`).
- **No execution of untrusted input in v1** — find is a code read + optional scanner invocation, NOT fuzzing/PoC-execution of malformed inputs. That keeps defend off the sandbox/isolation requirement the harness carries for its exploit-crafting agents; an adapter that ever executes a PoC would need that isolation and is out of v1 scope.
- **Real-vs-noise is gated, not asserted** — a candidate promotes to a finding only on an executable oracle or a corroborated, cited, reachable judgment; unconfirmed candidates are refuted to informational, never a patch proposal.
- **Findings dedupe by root cause** — within-run and against prior runs, keyed on sink identity, not drift-prone line numbers.
- **Tool availability honored** — unavailable scanner/skill ⇒ `ran: false`, no invented finding or claimed-but-unrun patch.
- **Report surface fits the mode** — interactive end-of-run report by default; a GitHub issue only on opt-in, sanitized on a public repo.

## Stop conditions / escalation to the user

- **No stack detected AND no test command** — no verify oracle exists for any auto class and the LLM-read hunt is the only mode; run it, but STOP before any auto-patch and report that all findings are propose-only.
- **A finding's fix requires an architectural change** (not a localized patch) — do NOT construct a patch wave; surface it as an informational finding with a note that it needs a scoped design decision, not a mechanical fix.
- **Patch verify fails twice on the same finding, same root cause** — STOP that finding's remediation, report it as unpatched with the failure, leave the finding's checkbox for a human to reconsider (same verify-twice discipline as `looper-verify`).
- **A scanner or sub-skill defend needs is unavailable** — log `ran: false`, continue the hunt in the degraded mode, and state the gap in the report; never fabricate the missing tool's output.
- **The target is not the current repo / reaches outside it** — defend hunts the repo it is run in; it does not reach across repos (that is custodian's explicit-list domain).
- **Conflicting authoritative severity/exploitability judgment defend can't arbitrate** — surface both readings to the user rather than picking one silently.

## What looper-defend does NOT do

- Does NOT auto-fix application code — patch is propose-only; only the narrow dep-bump class auto-proceeds, and even it lands as a reviewable draft-PR commit the human merges.
- Does NOT reinvent a patcher — remediation routes through `looper-build` → `looper-verify` → `looper-commit`, the same pipeline every wave uses.
- Does NOT reimplement `security-review` or `the-diamantaire` — those review the pending diff; defend hunts the whole repo, and may invoke `/security-review` as one input signal, not as its engine.
- Does NOT take a hard dependency on any hosted scanner/binary/account — adapters are optional and runtime-detected; the loop runs without them (`[[no-third-party-hosted-tool-reliance]]`).
- Does NOT execute untrusted input or craft/run PoCs in v1 — a code read + optional scanner invocation, so it carries no sandbox requirement.
- Does NOT parse free-text approval — `P-<n>` checkboxes only, read back from the run report.
- Does NOT promote a candidate to a reported finding without an executable oracle or a corroborated, cited, reachable judgment — unconfirmed candidates are refuted to informational.
- Does NOT patch a finding whose fix is an architectural change, or double-patch a finding already fixed (idempotent).
- Does NOT record a finding or a patch it didn't produce — unavailable tool ⇒ `ran: false`, no invented outcome.
- Does NOT open a GitHub issue per run — the default surface is an interactive end-of-run report; an issue is opt-in and sanitized on a public repo.
- Does NOT run on a cron — on-demand only, unlike `looper-custodian`.
- Does NOT reach beyond the repo it is run in.

## Integration with existing pieces

- `looper-build` / `looper-verify` / `looper-commit` — the remediation pipeline. Defend builds the wave brief and routes; it never patches directly.
- `security-review` (built-in) — an optional input signal for the pending-diff sub-case in triage; not defend's engine.
- `the-diamantaire` — reactive diff-review crew member; defend is the proactive whole-repo complement, and borrows its refute-or-promote posture for triage.
- `looper-custodian` — the sibling on-a-cadence maintenance layer; defend mirrors its propose/dispose split, `apply #<id>` grammar, `local/<tool>/<id>/` artifacts, and `ran: false` honesty, but hunts a target codebase on demand rather than housekeeping the looper system weekly.
- `loop-de-looper` — when defend runs under the orchestrator, patch waves are handed to `the-looper` dispatch rather than invoked directly; the findings log follows the same `verified_by`/`outcome` discipline as `gates.jsonl`.
