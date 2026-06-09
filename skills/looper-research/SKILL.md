---
name: looper-research
description: Research how to fix bugs and implement features. Trigger when the user says "look up how to do this", "how do I fix this bug?", or "how do I build this feature?"
---

Produce structured research report. Give looper-build everything need ship without guessing. Layer sources most authoritative to least. Challenge scope before recommend build.

## Layer 1: Project context (always)

- Read project's `CLAUDE.md` files (root + any nested `.claude/CLAUDE.md` + `.cursor/rules` if present)
- Read PRD if exist — default location `local/prds/<feature-slug>.md`. If unsure, check memory `reference-prds`.
- Read surrounding code: file being modified, its imports, its callers, its tests
- Check `package.json` for actual installed framework versions BEFORE referencing API/syntax. Training-data version assumptions break (Tailwind v3 vs v4 = recurring trap).
- Search project memory at `~/.claude/projects/<project>/memory/` — read `MEMORY.md` index, then any relevant `feedback-*` / `project-*` / `reference-*` entries.

## Layer 2: Authoritative domain references

For task's domain, pull official sources before community. Use `WebFetch` actually retrieve page — no cite from training data. Training data drifts; WCAG criteria, framework APIs, security advisories all evolve.

| Domain | Primary source |
|---|---|
| Accessibility | https://www.w3.org/WAI/WCAG22/Understanding/ — cite specific SC numbers and thresholds |
| Web platform | https://developer.mozilla.org/ |
| Framework | The framework's own docs (React, Vue, Vite, Tailwind, NestJS, etc.) — match the installed version |
| Database | The DB engine's manual (Postgres, MySQL, etc.) |
| Security | OWASP, CVE database, framework security advisories |

**Accessibility work — non-negotiable lookups:**

- WCAG 2.2 SC 1.4.3 Contrast (Minimum): 4.5:1 normal text, 3:1 large text. https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum
- WCAG 2.2 SC 1.4.11 Non-text Contrast: 3:1 for UI components and graphical objects (INCLUDING BORDERS that convey meaning). https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast
- WCAG 2.2 SC 1.4.1 Use of Color: info conveyed by color must also convey by shape/icon/text
- Color Vision Deficiency types: protanopia, deuteranopia, tritanopia, monochromatism — palette must distinguish state surfaces under ALL four
- Test border contrast against BOTH bundle-bg AND any adjacent surface (e.g. page bg) border touches. Most-missed check.

## Layer 3: Community sources (last resort)

Stack Overflow, GitHub issues, Reddit, DEV.to — only when authoritative sources miss case. Use `WebSearch` find candidates, then `WebFetch` read actual answer. Require ≥2 corroborating sources before treat community advice as truth.

## Scope challenge (always for refactors + pilots)

When user picks pilot or scope, evaluate before recommend build:

- Refactor pilot: proposed slice REPRESENTATIVE or ANOMALOUS? Pilot simplest representative case, not most-bespoke. Stress-test bespoke last.
- Feature: scope cohesive or bundle unrelated work?
- Wrong scope: surface as question, not refusal. User decides with full info.

Example: user says "pilot the theme refactor on Apollo 10½." Apollo carries CVD-mandated palette constraints (PRD footnote ^1). Wrong pilot — pilot vanilla theme like `school-of-rock` first, save Apollo as stress-test. Research flag this BEFORE recommend build.

## Output (hand to looper-build)

Structured report:

1. **Domain constraints** — non-negotiable rules with citations (WCAG SC numbers + thresholds, security invariants, perf budgets, etc.)
2. **Project context** — relevant CLAUDE.md rules, memory entries with `[[wikilinks]]`, related files
3. **Sources** — links + extracted facts (not vibes)
4. **Pre-build gates required** — which specialist subagents looper-orchestrator must invoke via Task tool BEFORE build (e.g. `accessibility-agents:accessibility-lead` for any color/contrast/theme work)
5. **Scope sanity check** — scope make sense? Concerns? Pilot recommendation if applicable.
6. **Open questions** — anything build cannot proceed on without user input

Sources conflict, no authoritative arbiter → STOP, surface to user. No pick arbitrarily.