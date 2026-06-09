---
name: looper-research
description: Research how to fix bugs and implement features. Trigger when the user says "look up how to do this", "how do I fix this bug?", or "how do I build this feature?"
---

Produce a structured research report that gives looper-build everything it needs to ship without guessing. Layer sources from most authoritative to least. Challenge scope before recommending build.

## Layer 1: Project context (always)

- Read project's `CLAUDE.md` files (root + any nested `.claude/CLAUDE.md` + `.cursor/rules` if present)
- Read the PRD if one exists — default location `local/prds/<feature-slug>.md`. If unsure, check memory `reference-prds`.
- Read surrounding code: the file being modified, its imports, its callers, its tests
- Check `package.json` for actual installed framework versions BEFORE referencing API/syntax. Training-data assumptions about versions break (Tailwind v3 vs v4 is a recurring trap).
- Search project memory at `~/.claude/projects/<project>/memory/` — read `MEMORY.md` index, then any relevant `feedback-*` / `project-*` / `reference-*` entries.

## Layer 2: Authoritative domain references

For the task's domain, pull from official sources before community ones. Use `WebFetch` to actually retrieve the page — do not cite from training data. Training data drifts; WCAG criteria, framework APIs, and security advisories all evolve.

| Domain | Primary source |
|---|---|
| Accessibility | https://www.w3.org/WAI/WCAG22/Understanding/ — cite specific SC numbers and thresholds |
| Web platform | https://developer.mozilla.org/ |
| Framework | The framework's own docs (React, Vue, Vite, Tailwind, NestJS, etc.) — match the installed version |
| Database | The DB engine's manual (Postgres, MySQL, etc.) |
| Security | OWASP, CVE database, framework security advisories |

**For accessibility work specifically — non-negotiable lookups:**

- WCAG 2.2 SC 1.4.3 Contrast (Minimum): 4.5:1 normal text, 3:1 large text. https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum
- WCAG 2.2 SC 1.4.11 Non-text Contrast: 3:1 for UI components and graphical objects (INCLUDING BORDERS that convey meaning). https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast
- WCAG 2.2 SC 1.4.1 Use of Color: information conveyed by color must also be conveyed by shape/icon/text
- Color Vision Deficiency types: protanopia, deuteranopia, tritanopia, monochromatism — palette must distinguish state surfaces under ALL four
- Test border contrast against BOTH bundle-bg AND any adjacent surface (e.g. page bg) the border touches. The most-missed check.

## Layer 3: Community sources (last resort)

Stack Overflow, GitHub issues, Reddit, DEV.to — only when authoritative sources don't cover the case. Use `WebSearch` to find candidates, then `WebFetch` to read the actual answer. Require ≥2 corroborating sources before treating community advice as truth.

## Scope challenge (always for refactors + pilots)

When the user picks a pilot or scope, evaluate it before recommending build:

- For a refactor pilot, is the proposed slice REPRESENTATIVE or ANOMALOUS? Pilot the simplest representative case, not the most-bespoke. Stress-test bespoke cases last.
- For a feature, is the scope cohesive or does it bundle unrelated work?
- If the scope is wrong, surface as a question, not a refusal. Let the user decide with full information.

Example: user says "pilot the theme refactor on Apollo 10½." Apollo carries CVD-mandated palette constraints (PRD footnote ^1). Wrong pilot — pilot a vanilla theme like `school-of-rock` first, save Apollo as the stress-test. Research should flag this BEFORE recommending build.

## Output (hand to looper-build)

Structured report:

1. **Domain constraints** — non-negotiable rules with citations (WCAG SC numbers + thresholds, security invariants, perf budgets, etc.)
2. **Project context** — relevant CLAUDE.md rules, memory entries with `[[wikilinks]]`, related files
3. **Sources** — links + extracted facts (not vibes)
4. **Pre-build gates required** — which specialist subagents looper-orchestrator must invoke via Task tool BEFORE build (e.g. `accessibility-agents:accessibility-lead` for any color/contrast/theme work)
5. **Scope sanity check** — does the scope make sense? Any concerns? Pilot recommendation if applicable.
6. **Open questions** — anything the build cannot proceed on without user input

If sources conflict and no authoritative arbiter exists → STOP and surface to user. Do not pick arbitrarily.
