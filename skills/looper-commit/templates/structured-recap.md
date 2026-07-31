# Structured recap block formats

Formats + examples for the three PR-body recap sub-blocks. Governing rules,
such as recap purpose, three-blocks-in-order, small-diff skip, mandatory
a11y call-out, grounding + secret redaction, and who decides when all live
in SKILL.md `## Structured recap (PR-body section)`.

Consult this file only when composing the block.

## 1. File-tree w/ change flags

```
skills/
  looper-commit/
    SKILL.md          [M]
  looper-recap/
    SKILL.md          [A]
src/
  lib/
    legacy-pad.ts     [D]
    format.ts         [R] (from fmt.ts)
```

Legend:

- `[A]` added
- `[M]` modified
- `[D]` removed
- `[R]` renamed

One tree, whole run. This is the map the other blocks index.

## 2. Collapsed `<details>` diff hunks w/ annotations

For each key changed file, a collapsible block GitHub renders natively.
Collapsed by default, so the PR body stays scannable. Budget 2–4 key files.
Skip mechanical churn. Each block holds a REAL diff excerpt plus a few
high-signal annotation notes:

````markdown
<details>
<summary><code>src/lib/format.ts</code>: Drop legacy pad() path</summary>

```diff
@@ -12,7 +12,7 @@ export function format(x) {
-  return pad(x, 2)
+  return x.toString().padStart(2, "0")
```

- `pad()` is gone; removed in `legacy-pad.ts` (see tree)
- Identical output for x < 100; diverges above
</details>
````

Keep each excerpt block tight, < 40 lines.Annotations answer what changed,
why, and any gotchas. Not a line-by-line restatement of the diff.

## 3. UI before/after ASCII wireframe + a11y risk

```
Before                  After
┌──────────────┐        ┌──────────────┐
│  [ Submit ]  │        │ [ Submit ▸ ] │
└──────────────┘        └──────────────┘

A11y risk: The new ▸ glyph is decorative. Needs aria-hidden, else the
button's accessible name reads "Submit right-pointing triangle".
```
