# The report issue — how the body is rendered

What the body is sanitized of and what it keeps verbatim, how each phase's
line is spelled in every state it can carry, and the plain-lead shape every
checkbox opens with. SKILL.md `## The report issue` is the pointer site and
keeps the routing — why the surface is an issue at all, its title, the
quiet-week rule, and how a human approves. Consult this file when writing or
changing a report body.

## Sanitization

- **Public repo → the body is written SANITIZED by default (hard rule).** `agents-of-shield-if-shield-is-ai` is a **public** repo, so the auto-mode classifier blocks a `gh issue create` whose body carries excess internal detail — and the unattended cron cannot answer that prompt, so a non-sanitized body hard-blocks the weekly publish (2026-07-20 resume hit exactly this). The full per-line detail already lives in `custodian-log.jsonl` (gitignored, local). So the issue body keeps only what a human needs to _approve a checkbox_, and pushes the rest to the local log. **Strip from the body:** other repos' branch names + PR numbers (Phase A/C → give counts + a repo-agnostic gloss, e.g. "reaped 8 merged dirs across 3 repos"; keep exact `repo/branch:line` cites in the log only); crew **agent code names** (use the role — "the documentation-review crew agent", "the agent-refiner", "the pre-flight adversary", "the verify skill"); and **absolute `~/.claude/…` paths** (name the memory/skill by its bare slug, not its filesystem path). **Keep verbatim:** Phase B's quoted memory _evidence lines_ — those are this repo's own memory, they're what the human verifies the proposal against, and they carry none of the flagged cross-repo/agent/abs-path detail. State once at the top of the body that specifics were kept off the public issue on purpose. (If a body still trips the classifier, trim further — never work around the denial.)

## The body's phase lines

- **Body** mirrors the phases: A reaped (info) / B proposals (checkboxes) / C digest (info) / E research (info + any checkboxes). When E was skipped by the usage-window gate, its line reads `E: deferred — usage window at N%, resets ~HH:MM; finish with /looper-custodian resume <date>` instead of a digest — the report still ships on C/A/B. When E ran but verified nothing, the line carries the reason rather than a bare zero: `E: degraded — N candidates, 0 verified (verification collapsed, M/M panels errored, window at P%); informational only, re-runs next cron`. The body also carries one line for the phase-order check (`scripts/custodian-phase-order.sh`, run over this run's own log just before the body is written): `phase order: every phase E was logged after a phase B` — the clean line names what held rather than saying "log ordered", which parses two ways and is jargon on a phone at 09:00; and it has to cover both predicates, since a segment whose phase E has no phase-B line logged at or before it is not ordered either; or `phase order: N phase-E line(s) logged ahead of a phase-B line — cites in custodian-log.jsonl`; or `phase order: N segment(s) logged phase E with no phase-B line logged at or before it, so their order cannot be shown — cites in custodian-log.jsonl` (the two count lines combine when both fire); or, when the check read no phase record at all, `phase order: NOTHING CHECKED — the log carried no readable phase record, so nothing was asserted`. That last one is spelled `NOTHING CHECKED`, the string the check itself prints — one state, one spelling, greppable across the report and the log — and it is a schema/plumbing failure of the check itself, never a clean run, which the body says rather than reporting silence as order. It is a report line, not an abort — the run has already happened, so stopping it buys nothing — and it speaks about the log's order, never the runtime's (SKILL.md `## Maintenance run`).

  The B line carries its coverage on both axes, because a clean bill is only valid at full coverage on both (SKILL.md `### Phase B`): `B: N proposals · 48/48 files, 214/214 citations resolved` when neither is short. When the file axis is short it reads `B: partial — 41/48 audited`, the spelling that phase verdict already carries. When every file was read but citations were not, it reads `B: partial — 48/48 files, 197/214 citations resolved (17 UNRESOLVED — see custodian-log.jsonl)`, and when both are short the two clauses combine: `B: partial — 41/48 audited, 172/189 citations resolved`. `partial` is what every short form leads with, because a line reading `48/48 files` and nothing else is the exact reassurance this second axis exists to withhold. The `UNRESOLVED` count goes in the body; which citations they were stays in the local log, per the sanitization rule above.

  The A line carries a second sentence for the snapshot audit (`scripts/loop-state-audit.sh` over each kept dir): `run snapshots: N kept dir(s) agree with their records` when every audited dir exited 0, or `run snapshots: N of M kept dir(s) disagree with their records — <branch>, <branch>` naming them, so the branch to resume is in the report rather than one command away. A dir the audit could not fully settle reads `run snapshots: N of M kept dir(s) could not be fully checked — <branch>`, kept distinct from agreement for the same reason `NOTHING CHECKED` is: an audit that declined is not an audit that passed. The A line carries a third sentence for the receipts check (`scripts/loop-receipts.sh` over the same kept dirs): `run receipts: N kept dir(s) back their executable claims` when every audited dir exited 0, or `run receipts: N of M kept dir(s) claim executable verification with no runtime receipt behind it — <branch>` naming them. A dir predating the hook reads `run receipts: N of M kept dir(s) predate the receipt hook, so nothing was asserted` — kept distinct from agreement for the same reason `NOTHING CHECKED` is.

Nothing here is a checkbox — the fix is to resume the run or repair its snapshot by hand, both of which are the owner's call, not a proposal the cron can stage.

## Checkbox shape

- **Every actionable proposal is a checkbox tagged** `B-merge-1`, `B-retire-5`, `B-repoint-4`, `B-migrate-2`, `D-turncoat-2`, `E-3` — with verbatim evidence inline.
- **Every checkbox LEADS with a plain-language explanation (hard rule).** The report is read by a human skimming on their phone, not a compiler. So the FIRST thing in any checkbox is one or two sentences — no more — saying, in plain words, what this is and why you'd tick it: no jargon, no cite syntax, no field names, no file paths, no tag codes. The detailed technical body — the verbatim evidence quotes, the failed relocation search, file paths, the `validate-by` method — FOLLOWS that plain lead, as much of it as the item needs. The verbatim-citation discipline is unchanged: evidence is still quoted exactly, it just no longer opens the checkbox. A proposal that leads with a legal-treatise sentence, however precise, does not meet the bar. Each phase section in the body likewise opens with a one-sentence plain summary before its detail or checkboxes. The before/after shape:

  ```text
  LEGAL-TREATISE SHAPE — do NOT lead like this:
  - [ ] B-retire-3 — Memory feedback-old-probe.md:12 cites --ratelimit-probe;
    existence-plus-grep against the user-global root is empty, relocation search
    grep -rl ratelimit-probe empty, git log -S ratelimit-probe shows removal.
    Retire per provably-gone-not-moved; breadcrumb [[feedback-old-probe]].
    validate-by: path-check.

  PLAIN-LEAD SHAPE — do this (plain first, detail after):
  - [ ] B-retire-3 — A saved note points at a command-line flag that no longer
    exists anywhere, so the advice it gives can't be followed. It's safe to drop.
    Memory feedback-old-probe.md:12 cites --ratelimit-probe. Existence-plus-grep
    against the user-global root is empty; relocation search grep -rl
    ratelimit-probe across the memory dir + scripts is empty; git log -S
    ratelimit-probe shows removal. Retire, leave a [[feedback-old-probe]]
    breadcrumb. validate-by: path-check.
  ```
