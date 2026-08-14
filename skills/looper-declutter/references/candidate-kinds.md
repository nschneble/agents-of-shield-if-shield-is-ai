# Candidate kinds + snip routing

What `scripts/doc-bloat-scan.sh` emits, and which owner's rule disposes each kind. Loaded by `SKILL.md` `### Scan` and `## Snip routing`.

Two rules govern this whole file. **The detector proposes, it never decides** — it emits candidates, never verdicts, never edits, and never gates (exit 0 always). **Declutter carries no comment-style constants of its own** — every disposition below cites an owner, and when an owner's rule changes declutter inherits it with no edit here.

## The six kinds

The detector emits one JSONL candidate per hit — `{file, line, kind, text}`. Scope is v1: C-style `//` and `/* */` plus JSX's braced `{/* … */}` spelling of the latter, full-line comments only, so a `//` inside a string or an `https://` URL is never mis-read.

- `block-overexplained` — a bare `/* … */` or `{/* … */}` block spanning multiple lines (at least one content line between opener and closer), `*`-prefixed or free-form prose alike. The primary quarry: a multi-line block wedged mid-execution. A free-form block whose lines don't start with `*` used to be invisible — the worst offender slipped the net; it no longer does.
- `jsdoc-block` — the same shape but a `/**` (or `{/**`) opener, i.e. a doc header. NOT kept by default: declaration position buys placement, not length, so an unbraced header survives only on an external-contract surface or when it collapses to a single earned line. The braced `{/**` is never a header at all: it parses only in JSX children position, so it is mid-execution by construction and routes to `block-overexplained`.
- `jsdoc-oneline` — a `/** … */` (or `{/** … */}`) opening and closing on ONE line. Flagged for EXISTING, not for length: the `/**` spelling declares a symbol doc, and a symbol doc is what a per-prop block is, so this is the kind that reaches "props get no docs" (`the-chronicler.md` `## Internal code`). Its bare twin, a one-line `/* … */`, is an inline note and is deliberately NOT a candidate — that is the genuine-one-liner survivor class.
- `stacked-slashes` — two or more consecutive `//` lines
- `over-75` — a comment line longer than 75 chars (break belongs at column 76)
- `capitalized-slash` — a single-line `//` whose first word is Capitalized

## Snip routing — reuse owners, never duplicate them

The heart of the skill. Each kind maps to an existing rule; declutter applies the owner's rule, it does not restate it:

| Kind                  | Owner rule (source of truth)                                                                                                                             |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `block-overexplained` | the primary quarry — a free-form `/* … */` or `{/* … */}` block. Collapse to ONE `// WHY` line or delete (`the-chronicler` `## Comment Style Rules`: one line is the ceiling for internal code). Justifies correct code / narrates a user → `the-chronicler` `## Do NOT document` (justifier, user story); explains a known primitive / restates code → `the-improver` deletes it; glosses a design-token/color/style that IS the answer → `the-chronicler` `## Do NOT document`. |
| `jsdoc-block`         | a `/**` (or `{/**`) doc header, and NOT keep-leaning. It survives only on an external-contract surface (`the-chronicler` `## External contract → thorough`) — Swagger, DTO fields, README, public API. Anywhere else, declaration position buys placement not length: collapse to the one earned line or delete, same disposition as `block-overexplained`. A braced `{/**` never reaches declaration position at all, since it parses only in JSX children position. |
| `jsdoc-oneline`       | a one-line symbol doc. Length is already at the ceiling, so the question is whether the doc should EXIST: on an external-contract surface (a DTO field, a public API) it stays; on a prop or any internal symbol it goes, because props get no docs and a symbol needing a gloss is misnamed (`the-chronicler` `## Internal code`). Judge the content too — a justifier, user story, explainer, restater, or gloss burns on one line exactly as it does on four. |
| `stacked-slashes`     | `the-chronicler` — collapse the wall to one WHY line, or delete if it only narrates the code                                                             |
| `over-75`             | `the-chronicler` — wrap/tighten to ≤ 75 chars (break at column 76)                                                                                       |
| `capitalized-slash`   | `the-chronicler` — lowercase the first word of a single-line `//`                                                                                        |
| every surviving line  | `the-ghostwriter` `## Comment cleanup mandate` + `## AI-slop blocklist` — de-slop, kill commit/wave archaeology, no em-dash                              |

The snip brief cites the owning rule per candidate. This is the anti-duplication contract — the agents explicitly guard against a second pass doing the same work (`the-chronicler.md`, `the-ghostwriter.md` cross-reference each other), and declutter honors it.
