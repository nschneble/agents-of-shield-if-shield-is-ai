#!/usr/bin/env bash
# Validates the looper config surface: every agent and skill spec has the
# frontmatter the harness needs, the declared name matches its path,
# backtick'd repo-relative path references resolve to real files, and every
# test suite in the repo is wired into the CI workflow.
#
# Frontmatter problems are ERRORS (exit 1) — a malformed name/description can
# silently break agent/skill resolution. An unwired test suite is an ERROR
# too: a suite CI never runs is a red nobody sees (doc-bloat-scan.test.sh
# sat out of the workflow for a week while failing). The wiring match reads
# ONLY the command text CI executes, so it errs toward calling a suite
# UNWIRED — the cheap direction: a false error costs a minute, a false
# "wired" reproduces that silent week. Dangling path references are
# WARNINGS (printed, non-fatal) — they catch doc rot without blocking on a
# clever false-positive. `[[memory-links]]` are intentionally NOT checked:
# a dangling one is a valid forward-reference per the memory convention.
#
# Run from anywhere; resolves the repo root itself. Wire into CI (see
# .github/workflows/validate.yml) and run locally before committing spec edits.

set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root" || exit 1

errors=0
warnings=0

err()  { printf 'ERROR  %s\n' "$1" >&2; errors=$((errors + 1)); }
warn() { printf 'WARN   %s\n' "$1" >&2; warnings=$((warnings + 1)); }

# Extract a top-level frontmatter scalar (name/description) from a spec file.
# Reads only the block between the first two `---` fences.
frontmatter_value() {
  awk -v key="$2" '
    NR == 1 && $0 != "---" { exit 1 }
    NR == 1 { infm = 1; next }
    infm && $0 == "---" { exit 0 }
    infm {
      # match `key:` at column 0, capture the rest
      if ($0 ~ "^" key ":[[:space:]]*") {
        sub("^" key ":[[:space:]]*", "")
        print
        exit 0
      }
    }
  ' "$1"
}

has_frontmatter() {
  [ "$(head -n 1 "$1")" = "---" ]
}

# --- Reference integrity: backtick'd file paths must exist ---
# Conservative: only tokens that look like a concrete file under one of the
# tracked dirs, with no glob/placeholder chars. Skips `skills/*/SKILL.md`,
# `local/loops/<branch>/...`, prose, and absolute/home paths. `templates/...`
# and `references/...` tokens are skill-relative: resolved against the citing
# spec's own directory.
check_references() {
  local file="$1" token target
  local dir; dir=$(dirname "$file")
  # Pull every `backtick`-wrapped token, one per line. The backticks are literal
  # regex chars, not shell expansion — single quotes are intentional. Process
  # substitution (not a pipeline) so warn's counter survives the loop.
  # shellcheck disable=SC2016
  while IFS= read -r token; do
    case "$token" in
      agents/*|skills/*|docs/*|scripts/*) target="$token" ;;
      templates/*|references/*) target="$dir/$token" ;;
      *) continue ;;
    esac
    # Skip globs / placeholders / anchors / non-file tokens.
    case "$token" in
      *'*'*|*'<'*|*'>'*|*'('*|*')'*|*' '*|*'#'*) continue ;;
    esac
    # Must look like a file (has a known extension).
    case "$token" in
      *.md|*.sh|*.json|*.yml|*.yaml|*.plist|*.ts|*.tsx) : ;;
      *) continue ;;
    esac
    [ -e "$target" ] || warn "$file references \`$token\` which does not exist"
  done < <(grep -oE '`[^`]+`' "$file" 2>/dev/null | tr -d '`')
}

validate_spec() {
  local file="$1" expected_name="$2" name desc
  if ! has_frontmatter "$file"; then
    err "$file has no frontmatter (must start with \`---\`)"
    return
  fi
  name=$(frontmatter_value "$file" name)
  desc=$(frontmatter_value "$file" description)
  # Strip one layer of surrounding quotes (specs mix `name: foo` and `name: "foo"`).
  name=${name#[\"\']}; name=${name%[\"\']}
  [ -n "$name" ] || err "$file missing or empty \`name:\`"
  [ -n "$desc" ] || err "$file missing or empty \`description:\`"
  if [ -n "$name" ] && [ "$name" != "$expected_name" ]; then
    err "$file declares name \`$name\` but path implies \`$expected_name\`"
  fi
  check_references "$file"
}

# --- Agents: agents/<name>.md, skip *.original.md backups ---
for f in agents/*.md; do
  [ -e "$f" ] || continue
  case "$f" in *.original.md) continue ;; esac
  base=$(basename "$f" .md)
  validate_spec "$f" "$base"
done

# --- Skills: skills/<name>/SKILL.md ---
for d in skills/*/; do
  [ -d "$d" ] || continue
  skill=$(basename "$d")
  f="${d}SKILL.md"
  if [ ! -e "$f" ]; then
    err "skill dir \`$skill\` has no SKILL.md"
    continue
  fi
  validate_spec "$f" "$skill"
done

# --- CI wiring: every *.test.sh needs a step in the validate workflow ---
# Derived from the tree, never a hand-kept roster: a roster is what rotted.
# `local/` is gitignored scratch, not CI's business. Process substitution
# (not a pipeline) so err's counter survives the loop.

# Emit only the shell CI actually runs: the text after an inline `run:`,
# and the body lines of a `run: |` / `run: >` block scalar. Two shapes
# both have to hold. Reading the whole YAML body accepts any MENTION — a
# step `name:`, an `on: push: paths:` filter, a `# TODO re-enable
# ./x.test.sh` comment — each of which passed while the real step was
# deleted. Reading only lines matching `run:` misses the block scalar,
# which is the bug that widening was meant to fix. So: strip `#` to end of
# line (a whole-line comment collapses to whitespace and contributes
# nothing), then track the block. A block scalar's body is indented past
# the column of its own `run` key, which is what ends the block on the
# next sibling key or list item.
run_commands() {
  awk '
    { sub(/#.*/, "", $0) }
    in_run {
      if ($0 ~ /^[[:space:]]*$/) next          # blank lines stay inside
      match($0, /^[[:space:]]*/)
      if (RLENGTH > run_col) { print; next }
      in_run = 0                                # dedented: block is over
    }
    /^[[:space:]]*(-[[:space:]]+)?run:/ {
      run_col = index($0, "run:") - 1
      rest = $0
      sub(/^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*/, "", rest)
      if (rest ~ /^[|>]/) in_run = 1
      print rest
    }
  ' "$1" 2>/dev/null
}

workflow=".github/workflows/validate.yml"
if [ ! -e "$workflow" ]; then
  err "$workflow is missing, so no test suite runs in CI"
else
  run_cmds=$(run_commands "$workflow")
  while IFS= read -r suite; do
    case "$run_cmds" in
      *"./$suite"*) : ;;
      *) err "$suite is not invoked anywhere in $workflow" ;;
    esac
  done < <(find . -name '*.test.sh' -not -path './.git/*' -not -path './local/*' \
             | sed 's|^\./||' | sort)
fi

printf '\n%d error(s), %d warning(s)\n' "$errors" "$warnings" >&2
[ "$errors" -eq 0 ]
