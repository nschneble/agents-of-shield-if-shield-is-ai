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
#
# Deliberately over the ~100-line refactor bar, same waiver
# scripts/temp-dir-guard.test.sh carries. The three checks share one
# `errors` verdict and one repo-root resolution, and the wiring check has
# already been wrong in both directions — splitting it into a file that
# cannot see the frontmatter walk's file list is how a fourth spelling
# gets missed. Trim its prose before reaching for its code.

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

# --- Doc mirror: every declared subcommand verb reaches the family doc ---
# A skill and the doc that enumerates the family drift apart silently: the
# skill grows a verb, the doc keeps the old shape, and every existing check
# passes because both files are internally valid. Matches anywhere in the
# doc, not just its invocation table — the cheap direction, since a verb
# discussed in prose is documented and a false WARN costs more than a miss
# here. Verb-set membership only: the doc's `**Trigger:**` lines are
# deliberate abridgements of the descriptions, so comparing those would
# fire on nearly every skill.
family_doc="docs/looper-skills.md"
if [ -e "$family_doc" ]; then
  for d in skills/*/; do
    [ -d "$d" ] || continue
    skill=$(basename "$d")
    [ -e "${d}SKILL.md" ] || continue
    while IFS= read -r invocation; do
      grep -qF -- "$invocation" "$family_doc" \
        || warn "$family_doc omits \`$invocation\`, declared in ${d}SKILL.md"
    done < <(grep -ohE "/$skill [a-z][a-z-]*" "${d}SKILL.md" | sort -u)
  done
fi

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

# --- Deploy links: every shipped file must resolve through ~/.claude ---
# Definitions only run once ~/.claude points at them, so a file that exists
# here and is unreachable there is shipped in name only. Four reference
# files sat unlinked for weeks that way — SKILL.md cited them and the
# runtime could not load them. Derived from the tree for the same reason
# the CI check above is.
#
# WARN, never err: this is machine-local deploy state, not a property of
# the commit, and CI has no ~/.claude at all. Skipped whole when the tree
# is undeployed, so a fresh clone and CI both stay silent.

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

real_path() {  # realpath is not on stock macOS; readlink -f is not on bash 3.2 macOS either
  ( cd "$(dirname "$1")" 2>/dev/null && p=$(basename "$1")
    while [ -L "$p" ]; do
      t=$(readlink "$p")
      case "$t" in /*) cd "$(dirname "$t")" ;; *) cd "$(dirname "$t")" ;; esac 2>/dev/null || return 1
      p=$(basename "$t")
    done
    printf '%s/%s\n' "$(pwd -P)" "$p" )
}

if [ -d "$CLAUDE_HOME/agents" ]; then
  repo_root=$(pwd -P)
  for area in agents skills hooks; do
    [ -d "$area" ] || continue
    while IFS= read -r rel; do
      deployed="$CLAUDE_HOME/$area/$rel"
      if [ ! -e "$deployed" ]; then
        warn "$area/$rel is not deployed: no $CLAUDE_HOME/$area/$rel"
      elif [ "$(real_path "$deployed")" != "$repo_root/$area/$rel" ]; then
        warn "$area/$rel resolves to $(real_path "$deployed"), not this repo"
      fi
    done < <(find "$area" -type f ! -name '.DS_Store' | sed "s|^$area/||" | sort)
  done
fi

printf '\n%d error(s), %d warning(s)\n' "$errors" "$warnings" >&2
[ "$errors" -eq 0 ]
