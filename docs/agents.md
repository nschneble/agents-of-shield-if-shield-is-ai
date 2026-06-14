# Agents

## The Auditor

- **File:** `agents/the-auditor.md`
- **Tools:** `Bash, Edit, Read, Write`
- **When:** After writing or modifying any UI component, page, or styling

Accessibility architect. Audits and fixes WCAG 2.2 AA + ARIA APG patterns.
First principle: native HTML beats ARIA. Wrong ARIA is worse than none.
Covers landmarks, headings, focus management, keyboard ops, modal trapping,
live regions, contrast, forms, and screen reader semantics.

## The Chemist

- **File:** `agents/the-chemist.md`
- **Tools:** `Bash, Edit, Read, Write`
- **When:** After any significant feature implementation

Testing specialist. Covers both back-end and front-end tests. Philosophy:
coverage is a floor, every test must prove something can fail, no testing
mocks. Runs test scripts to find gaps. Writes e2e tests that mirror real
user flows. Actively prunes weak or duplicate tests.

## The Chronicler

- **File:** `agents/the-chronicler.md`
- **Tools:** `Bash, Edit, Read, Write`
- **When:** After new features, API changes, or any complex logic

Documentation guardian. **Depth scales with audience distance.** External
API contracts get thorough Swagger + DTO docs. Internal code gets smaller
inline comments. Leans on self-documenting names. Writes Swagger
decorators, README updates, and JSDocs on non-obvious modules.

## The Diamantaire

- **File:** `agents/the-diamantaire.md`
- **Tools:** `Bash, Read`
- **When:** Before merging any non-trivial change

Expert code reviewer. Focuses on correctness, performance, maintainability,
security, and convention alignment. Reviews recently modified code only.
Scores each finding 0–100 confidence and discards below 80 so it doesn't
get caught bike-shedding. Quotes CLAUDE.md verbatim when invoking rules.
Praises genuinely good decisions.

## The Improver

- **File:** `agents/the-improver.md`
- **Tools:** `Bash, Edit, Read, Write`
- **When:** After a feature works but before it's "done"

Refactoring specialist. Surgical, behavior-preserving. DRY but not barren.
No god files. Hunts for drift between alike components and enforces UI
fidelity across pages with alike content. Walks the **replace, don't
rebuild** ladder before reshaping custom code: YAGNI → stdlib → platform →
existing dep → one-liner → minimal custom.

## The Looper

- **File:** `agents/the-looper.md`
- **Tools:** `Bash, Edit, Glob, Read, Skill, WebFetch, WebSearch, Write`
- **When:** After the user asks to fix a bug or implement a feature

Autonomous bugfix and feature implementation worker. Runs the six looper
skills as a gated flow. Acts in an architectural role. Pre-build domain
gates like a11y-lead are invoked by the orchestrator and handed in as
research input.

## The Lunchlady

- **File:** `agents/the-lunchlady.md`
- **Tools:** `Bash, Edit, Read, Write, Task`
- **When:** When asked to run a desloppify code-quality pass

[Desloppify](https://github.com/peteromallet/desloppify) wave operator.
Detects project shape and language at invocation. Runs waves: **scan → fix
clusters → rescan**, looping while score climbs and cluster cap holds.
Score drop → revert. UI clusters gated through
`accessibility-agents:accessibility-lead`. Sub-projects run sequentially.

## The Stickler

- **File:** `agents/the-stickler.md`
- **Tools:** `Bash, Read`
- **When:** After implementing features, refactoring, or structural changes

Convention enforcer. Identifies violations and explains fixes. Checks
naming, TypeScript type usage, NestJS patterns, React patterns, Tailwind
class order, testing conventions, and accessibility attributes.

## The Turncoat

- **File:** `agents/the-turncoat.md`
- **Tools:** `Bash, Edit, Read, Write`
- **When:** When agents or skills feel verbose or over-privileged

Audits and streamlines other agents AND skills. Identifies bloat, redundant
instructions, unnecessary tool access, and stale guidance contradicting
current conventions. Applies the ponytail lens (lowest-viable rung) when
auditing agents that shape code. Proposes all rewrites before applying.
Watches for memory-as-behavioral-fix anti-patterns.

## The Wordsmith

- **File:** `agents/the-wordsmith.md`
- **Tools:** `Bash, Edit, Read, Write`
- **When:** Starting anything new

Creative engine. Handles the full range of components, modules, endpoints,
pages, and full scaffolds. Always researches first. For large features,
writes a PRD before scaffolding. TDD throughout. Quality gates include
tests, lint, no god files, proper naming conventions, barrel index,
accessible UI, and lean DB calls. **Minimum-viable bias:** walks the ladder
(YAGNI → stdlib → platform → existing dep → one-liner → minimal custom)
before code; richer solutions need a named requirement (perf, a11y,
security, data-loss, trust-boundary).

---

## "The Crew"

The Auditor, Chemist, Chronicler, Diamantaire, Improver, and Stickler are
the six **existing-code agents** invoked on code that already exists.

If you run them in series (instead of parallel) then favor this order:

1. Improver
2. Stickler
3. Auditor
4. Chemist
5. Chronicler
6. Diamantaire

The Wordsmith builds new things. The Looper runs end-to-end bugfix and
feature flows via looper skills. The Lunchlady runs incremental
code-quality Desloppify passes. The Turncoat maintains the agents
themselves.
