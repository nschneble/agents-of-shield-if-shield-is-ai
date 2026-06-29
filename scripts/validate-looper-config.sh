#!/usr/bin/env bash
# Validates the looper config surface: every agent and skill spec has the
# frontmatter the harness needs, the declared name matches its path, and
# backtick'd repo-relative path references resolve to real files.
#
# Frontmatter problems are ERRORS (exit 1) — a malformed name/description can
# silently break agent/skill resolution. Dangling path references are WARNINGS
# (printed, non-fatal) — they catch doc rot without blocking on a clever
# false-positive. `[[memory-links]]` are intentionally NOT checked: a dangling
# one is a valid forward-reference per the memory convention.
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

# --- Reference integrity: backtick'd repo-relative file paths must exist ---
# Conservative: only tokens that look like a concrete file under one of the
# tracked dirs, with no glob/placeholder chars. Skips `skills/*/SKILL.md`,
# `local/loops/<branch>/...`, prose, and absolute/home paths.
check_references() {
  local file="$1" token
  # Pull every `backtick`-wrapped token, one per line. The backticks are literal
  # regex chars, not shell expansion — single quotes are intentional.
  # shellcheck disable=SC2016
  grep -oE '`[^`]+`' "$file" 2>/dev/null | tr -d '`' | while IFS= read -r token; do
    case "$token" in
      agents/*|skills/*|docs/*|scripts/*) : ;;
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
    [ -e "$token" ] || warn "$file references \`$token\` which does not exist"
  done
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

printf '\n%d error(s), %d warning(s)\n' "$errors" "$warnings" >&2
[ "$errors" -eq 0 ]
