---
name: looper-declutter
description: On-demand whole-repo comment-bloat sweep — find over-narrated comments and propose surgical snips, human-gated. Trigger when the user says "kill doc bloat", "declutter this repo", "trim the comments", or "run looper-declutter".
---

Proactive whole-repo comment-bloat hunt + human-gated snips. `looper-defend` hunts a target repo for security defects; `looper-declutter` hunts the same repo for over-explained comments and proposes surgical trims. Same shape (on-demand, whole-repo, propose-only, `apply`/`--dry-run`), different quarry.

Full design rationale + decision log: `docs/looper-declutter.md`. This file is the executable spec.

## Why this exists — and how it differs from what already trims comments

Comment discipline is already OWNED and already enforced — but only reactively, on a change-scoped diff:

- **`the-chronicler`** (mechanics: WHY-only depth, lowercase single-line `//`, 75-char wrap, no multi-line blocks mid-execution), **`the-ghostwriter`** (voice: the AI-slop de-slopper + commit/wave archaeology killer), and **`the-improver`** (deletes comments that restate code) run inside a crew pass over the PENDING diff (`looper-review`). They answer "is this CHANGE over-commented?"
- **`looper-declutter`** answers "is this REPO over-commented?" — a proactive sweep over the whole tree, independent of any pending change. A comment that was bloated before the reactive crew ever saw the file never got trimmed; this is the pass that reaches it.

Declutter does NOT reimplement those rules. It contributes exactly two new things: a **mechanical detector** (`scripts/doc-bloat-scan.sh`) that finds candidates across the whole tree, and the **orchestration** that routes each candidate to its existing owner. The rules stay where they live (`## Snip routing`).

## Governing principle: declutter PROPOSES, human DISPOSES

Same discipline the loop, custodian, and defend hold. A comment is a judgment call — an autonomous pass that auto-rewrites every flagged comment will flatten a deliberate GOTCHA, lowercase a proper noun, or truncate the one line that carries the real gotcha. So:

- **Scan / triage / report run automatically** — read-only, no source touched. They find, route, and rank candidates.
- **Snip is propose-only** — every trim lands as a checkbox in the report and proceeds through the build pipeline ONLY after a human ticks it. There is NO auto-apply class here (unlike defend's dep-bump): a comment edit is never mechanical enough to skip the tick.

The snip path also answers to the framework-wide attribution default (`docs/looper-framework.md` → `## Unexpected state is the owner's until proven otherwise`), which is why a comment that reads strangely is a candidate for the report, never a trim the pass makes on its own judgment.

## Invocation

Noun-verb grammar (`docs/looper-skills.md` → `## Subcommand grammar`), same shape as custodian and defend:

| Invocation                                     | Does                                                                                                                                                       |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/looper-declutter` (or an NL trigger)         | the **sweep run**: scan → triage → report, read-only, ends by emitting the structured report + persisting candidates                                       |
| `/looper-declutter apply #<snip-id>`           | **snip one candidate**: builds a doc-wave brief and routes it through `looper-plan` → `looper-build` → `looper-verify` → `looper-review` → `looper-commit` |
| `/looper-declutter apply <run-id>`             | **snip all ticked candidates** in that run, grouped one wave per file, idempotently                                                                        |
| `/looper-declutter apply #<snip-id> --dry-run` | **preview**: prints the proposed brief + the exact diff the snip would attempt, and writes nothing                                                         |

`apply` is the verb, `#<snip-id>`/`<run-id>` the arg, `--dry-run` the flag — the exact model custodian and defend use. Snip writes nothing without an `apply`. No bespoke `undo`: snips land as git commits on a **draft PR**, so the PR diff IS the preview and `git`/PR-close IS the reversal.

## The phases

Run in order. Each logs to `local/declutter/<run-id>/findings.jsonl` before the report. Scan/triage/report are read-only; only snip (via `apply`) writes.

### Scan — find candidates (read-only, mechanical)

Run the detector over the target tree. It ships in the looper definitions repo and deploys to `~/.claude/scripts/`, so it resolves from any cwd — including a target repo like Linklater, where a repo-relative path would not:

```
~/.claude/scripts/doc-bloat-scan.sh [<path> ...]
```

It emits one JSONL candidate per hit — `{file, line, kind, text}` — across six kinds: `block-overexplained`, `jsdoc-block`, `jsdoc-oneline`, `stacked-slashes`, `over-75`, `capitalized-slash`. What each one means and what disposes it: `references/candidate-kinds.md`.

The detector is the ONLY mechanical scan; it never edits and never gates (exit 0 always). Candidates are suggestions, not verdicts.

### Triage — route + rank (read-only)

For each candidate, decide keep-vs-snip and which owner's rule the snip applies (`## Snip routing`). The bar is AGGRESSIVE. the-chronicler's standing rule is already absolute — "One line is the ceiling for internal code. Anywhere." (`the-chronicler.md` `## Comment Style Rules`), on top of a zero default where a comment ships only if one of four named earners fires (`## Internal code`). The global CLAUDE.md says the same. Declutter ENFORCES those rules; it does not soften them. Exactly two things survive; everything else is a snip.

**What survives:**

- **External-contract prose.** Swagger/OpenAPI decorators, DTO field docs, README and public-API surfaces. Strangers read these and cannot read the source, so length is legitimate and thin is the defect (`the-chronicler.md` `## External contract → thorough`). This is the only place a multi-line block is safe from the axe.
- **Genuine one-liners.** A single-line `// loads metadata in an async job`, or a one-line `// GOTCHA:` / `// TODO:` / `// KNOWN ISSUE:` marker. One line, kept. A one-line `/* … */` inline note counts here too — but a one-line `/** … */` does NOT, because the `/**` spelling declares a symbol doc rather than a note, and the question for a symbol doc is whether it should exist at all (`jsdoc-oneline`).

Declaration position is NOT on this list. A `/**` block at the file top or before an `interface`/`type`/`function`/`export`/prop buys PLACEMENT, not length: `the-chronicler.md` `## Comment Style Rules` caps internal code at one line anywhere, declaration position included. A header essay is still an essay, and it is the offense that survives longest because it looks respectable. Collapse it to the one earned line, or delete it.

**What burns** — everything else, default verb DESTROY. A "non-obvious WHY" does NOT earn length; it earns ONE line or the axe. These are the reason this skill exists, and the reactive crew keeps letting them stand:

- **Justifies code for being CORRECT** — a defense of aria/a11y that works, focus that lands, errors that get caught, types that hold. Correct is the baseline, not a story, and the defense reads as patronizing to whoever wrote the code. → `the-chronicler` `## Do NOT document` (justifier). A genuinely unusual mechanism collapses to ONE short line (`// helps screen readers`); everything else goes.
- **Narrates a user, persona, or scenario** — a user story wedged into a source file, or prose about what someone would perceive. Source files have no audience section. → `the-chronicler` `## Do NOT document` (user story).
- **Explains a language / framework / library primitive** the reader already knows — what Tailwind's `group` does, what a hook or a keyword does. The reader is a working engineer, not a student. → `the-improver` deletes it.
- **Glosses the author's own named design** — narrating a hand-written style, token, color, or CSS variable (`border-shadow`) that IS the answer, as if the author had never seen it. → `the-chronicler` `## Do NOT document` (a design-token/color value needs no gloss).
- **Restates what the code plainly does.** → `the-improver` deletes it.
- **Any multi-line block outside an external contract** — mid-execution, at a declaration, or on a prop, all the same verdict. If a real gotcha is buried in it, collapse to ONE line that keeps the gotcha; otherwise delete. This is `the-chronicler.md` line-for-line.
- **Any per-prop doc, at any length — one line included.** Props get no docs at all, not per-field and not an interface-level summary; a prop that needs a gloss is misnamed and renaming it is the snip (`the-chronicler.md` `## Internal code`). This is what `jsdoc-oneline` exists to reach.

**Then dedupe, drop generated, rank:**

- **Dedupe by comment, not by kind.** One comment can trip several kinds (a stacked block that is also over-75 and Capitalized). Group them into ONE snip candidate for that comment, listing every kind it hit — never four separate checkboxes for one comment.
- **Generated / vendored code is out of scope.** The detector already honors `.gitignore` via `git ls-files`; triage additionally drops anything under obvious generated paths (`*.d.ts`, migrations, snapshots).
- **Rank** by density — files with the most snip candidates first, so a reviewer trims the worst offenders in one wave.

### Report — surface candidates (read-only)

An interactive end-of-run report to the user (like defend), plus a persisted `local/declutter/<run-id>/report.md` carrying the tickable proposals that `apply` reads back.

- Group candidates by file, each with: id `D-<n>`, `file:line`, the kinds it hit, the current comment, and the proposed snip.
- **Each actionable snip is a checkbox** tagged `D-<n>`. Keep/informational candidates are listed WITHOUT checkboxes.
- **No candidates → no report noise.** A clean tree says so in one line.
- To trim: tick the `D-<n>` boxes and run `/looper-declutter apply <run-id>` (or `apply #<snip-id>` for one).

### Snip — trim through the normal pipeline (gated)

Triggered by `apply`. Declutter does NOT edit directly — it feeds ticked candidates through the standard wave loop (`looper-plan` → `looper-build` → `looper-verify` → `looper-review` → `looper-commit`), the same chain every wave uses. Comment-only changes are a **doc wave** (`looper-build` doc-wave branch: `Edit`, run `format` + markdown lint, skip test/build).

- **Group one wave per file.** All of a file's ticked snips are one cohesive, behavior-preserving change — not one wave per comment.
- **Behavior-preserving, always.** A snip only edits comment text; it never touches code. `looper-verify` confirms the diff is comment-only (no token outside a comment moved) and the suite stays green; a snip that changes a non-comment byte is reverted.
- **Idempotent** — a comment already trimmed is a no-op. Re-running `apply` on the same run is safe.
- **Honor tool availability** — if declutter cannot invoke the pipeline skills (no Skill/Task tool), it logs `ran: false` and hands the brief back, never a claimed-but-unrun snip. Same discipline as custodian and defend.

## Snip routing — reuse owners, never duplicate them

The heart of the skill, and it lives in `references/candidate-kinds.md` `## Snip routing`. Each kind maps to an existing rule; declutter applies the owner's rule and carries no comment-style constants of its own, so an owner's rule change propagates with no edit here.

## Artifacts + findings log

Every phase logs to `local/declutter/<run-id>/findings.jsonl` before the report, and the report persists beside it as `report.md`. Record shapes, field semantics, and the `ran: false` honesty rule: `references/artifacts.md`.

## Safety rails

- **Propose-vs-dispose is the spine** — scan/triage/report read-only auto; snip gated behind a ticked `D-<n>` + explicit `apply`. No auto-apply class.
- **Comment-only, verified** — a snip never edits a non-comment byte; `looper-verify` enforces comment-only diff + green suite, else revert.
- **Snip routes through the normal pipeline** — never a bespoke editor; the PR diff is the preview, git/PR-close the reversal.
- **The detector is self-contained** — pure bash + awk, no third-party tool, no hosted dependency (`[[no-third-party-hosted-tool-reliance]]`).
- **Repo-scoped** — declutter hunts the repo it is run in; it does not reach across repos (that is custodian's explicit-list domain). On a public target, the same report sanitization discipline as custodian applies.
- **Tool availability honored** — unavailable Skill/Task ⇒ `ran: false`, no invented snip.

## Stop conditions / escalation to the user

- **A snip would drop a real gotcha** — a genuine invariant or GOTCHA is buried in the block → collapse to ONE line that keeps the gotcha, never keep the multi-line essay. Length is never how meaning is preserved; a one-liner is. Comment-survival keeps are narrow: external-contract prose and genuine one-liners. (A proper noun or identifier a mechanical snip would corrupt is held separately — next.)
- **A candidate points at a proper noun or identifier** the lowercase/wrap rule would corrupt → keep, flag for human judgment.
- **`looper-verify` fails twice on the same file** (a snip keeps touching non-comment bytes) → STOP that file's wave, report it unsnipped.
- **The target is not the current repo** — declutter hunts the repo it is run in; it does not reach across repos.

## What looper-declutter does NOT do

- Does NOT auto-edit comments — snip is propose-only, every trim needs a tick; there is no auto-apply class.
- Does NOT reimplement the comment rules — it routes to `the-chronicler` (mechanics), `the-ghostwriter` (voice), and `the-improver` (delete-restate) and carries no style constants of its own.
- Does NOT reinvent an editor — snips route through `looper-plan` → `looper-build` → `looper-verify` → `looper-review` → `looper-commit`, the same pipeline every wave uses.
- Does NOT touch code — a snip edits comment text only; a non-comment byte change is reverted.
- Does NOT take a hard dependency on any hosted tool — the detector is self-contained bash + awk.
- Does NOT parse free-text approval — `D-<n>` checkboxes only.
- Does NOT run on a cron — on-demand only, unlike `looper-custodian`.
- Does NOT reach beyond the repo it is run in.

## Integration with existing pieces

- `references/candidate-kinds.md` — the six detector kinds and the per-kind owner routing; `references/artifacts.md` — the `findings.jsonl` / `report.md` record shapes.
- `scripts/doc-bloat-scan.sh` (deployed to `~/.claude/scripts/`, so it resolves from any target repo) — the mechanical detector; declutter's only scan engine.
- `the-chronicler` / `the-ghostwriter` / `the-improver` — the comment-rule owners; declutter applies their rules, never duplicates them.
- `looper-review` — the reactive, change-scoped crew pass that trims NEW comment bloat; declutter is the proactive whole-repo complement, the same way `looper-defend` complements `security-review`.
- `looper-plan` / `looper-build` / `looper-verify` / `looper-review` / `looper-commit` — the snip pipeline, the full per-wave chain.
- `looper-custodian` / `looper-defend` — the sibling propose/dispose skills; declutter mirrors their `apply #<id>` grammar, `local/<tool>/<id>/` artifacts, and `ran: false` honesty, but hunts comment bloat on demand.
