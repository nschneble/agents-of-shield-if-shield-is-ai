# [Looper](agents/the-looper.md) skills

## Looper "build"

**File:** `skills/looper-build/SKILL.md`
**Trigger:** "Fix this bug" or "implement this feature"

Apply the research output as the smallest possible change. Quality gates
before done. **Pre-build domain gates are non-negotiable.** The
orchestrator (not the skill) must invoke specialist subagents via the
Task tool before write code begins:

| Touching                  | Gate                                      |
| ------------------------- | ----------------------------------------- |
| Auth, permissions, tokens | Security review                           |
| Database migrations       | Migration-safety review                   |
| Themes, contrast          | `accessibility-agents:accessibility-lead` |
| Web UI                    | `accessibility-agents:accessibility-lead` |

No Bash bypass. No proceeding without gate output in hand.

## Looper "learn"

**File:** `skills/looper-learn/SKILL.md`
**Trigger:** "Reflect on this" or "remember what we just did here"

Run after a looper suite to capture reusable lessons. Diagnoses each step
and saves lessons at the right persistence layer; memory for
project-specific facts, CLAUDE.md for standing conventions, and agent
definitions for behavioral constraints.

## Looper "commit"

**File:** `skills/looper-commit/SKILL.md`
**Trigger:** "Commit this wave", "create the PR", or "update the existing PR"

Final step of every wave. Always commits any code/doc changes. Auto-detects
PR state — if the branch has an existing PR, just commits to it; if no
existing PR, creates a draft assigned `@me`. External-state waves (PR body
refresh, GitHub release update) skip the commit but still confirm PR
context. Refuses if pre-flight fails (AC check, review verdict, lint/test/
build all passing, no stray untracked files). Never amends, never bypasses
hooks.

Renamed from `looper-pr` in framework v1.2 — the commit is the load-bearing
action; PR creation is downstream of it.

## Looper "research"

**File:** `skills/looper-research/SKILL.md`
**Trigger:** "How do I fix this bug?", or "how do I build this?"

Produces a structured research report that gives looper-build everything
needed to ship without guessing. Layers project context, authoritative
domain references, and community sources. Challenges scope before
recommending the build.

## Looper "review"

**File:** `skills/looper-review/SKILL.md`
**Trigger:** "Review this bugfix", or "review this feature"

Qualitative review, independent from build and verify. Question is not
"does it work" but "right shape, fits codebase, hidden costs?" Recommends
which specialist reviewers the orchestrator should invoke in parallel
via Task tool. Synthesizes findings.

## Looper "verify"

**File:** `skills/looper-build/SKILL.md`
**Trigger:** "Verify this bugfix" or "confirm this feature works"

Functional verification only. Does the change do what the spec said?
Distinct from review, which is qualitative. Re-reads the original spec,
lists acceptance criteria, exercises the change against golden path and 2–3
edge cases. For UI changes it starts dev server, clicks through in browser,
and screenshots. Ensures type-checks and tests pass. Doesn't auto-approve
visual regression baselines.

---

## The Flow

Research → Build → Verify → Review → Learn → Commit

- Repeat research/build/verify until the bug's fixed or feature's implemented
- Repeat review until satisfied.
- Learn captures any lessons
- Commit lands the wave (and opens a draft PR if no existing PR for the branch)

The [Looper agent](agents/the-looper.md) drives the skills. The
orchestrator invokes any pre-build domain gates.
