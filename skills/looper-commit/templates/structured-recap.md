# Structured recap block formats

Formats + examples for the three PR-body recap sub-blocks. Governing rules (what the recap is for, three-blocks-in-order, small-diff skip, the mandatory a11y call-out, grounding + secret redaction, and who decides WHEN) live in SKILL.md `## Structured recap (PR-body section)` — consult this file only when composing the block.

## 1. File-tree with change flags

```
skills/
  looper-commit/
    SKILL.md          [M]
  looper-recap/
    SKILL.md          [A]
src/
  lib/
    legacy-pad.ts     [D]
    format.ts         [R]  (was fmt.ts)
```

Legend: `[A]` added · `[M]` modified · `[D]` removed · `[R]` renamed. One tree, whole run — this is the map the other blocks index into.

## 2. Collapsed `<details>` diff hunks with annotations

For each load-bearing changed file, a collapsible block GitHub renders natively — collapsed by default so the PR body stays scannable. Budget roughly 3–8 key files; skip pure mechanical churn. Each block holds a REAL diff excerpt (fenced ` ```diff `) plus a few high-signal annotation notes:

````markdown
<details>
<summary><code>src/lib/format.ts</code> — drop the legacy pad() path</summary>

```diff
@@ -12,7 +12,7 @@ export function format(x) {
-  return pad(x, 2)
+  return x.toString().padStart(2, "0")
```

- `pad()` is now dead — removed in `legacy-pad.ts` (see tree).
- Identical output for x < 100; diverges above (old path truncated).
</details>
````

Keep each excerpt focused (~<150 lines) — the load-bearing hunk, not the whole file. Annotations answer what changed, why, and any gotcha — not a line-by-line restatement of the diff.

## 3. UI before/after ASCII wireframe + a11y risk

```
Before                       After
┌──────────────┐             ┌──────────────┐
│  [ Submit ]  │             │  [ Submit ▸ ]│
└──────────────┘             └──────────────┘

a11y risk: the new ▸ glyph is decorative — needs aria-hidden, else the
button's accessible name reads "Submit right-pointing triangle".
```
