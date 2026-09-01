#!/usr/bin/env bash
# validates the looper config surface: agent/skill frontmatter, backtick'd
# path + heading references, doc-mirror drift, and CI test-suite wiring.
# Wiring is an ERROR (a suite CI skips is a red nobody sees); dangling
# refs/mirrors are WARNINGS. Wire into .github/workflows/validate.yml.

set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root" || exit 1

errors=0
warnings=0

err()  { printf 'ERROR  %s\n' "$1" >&2; errors=$((errors + 1)); }
warn() { printf 'WARN   %s\n' "$1" >&2; warnings=$((warnings + 1)); }

# a top-level frontmatter scalar, read only from the first `---` block
frontmatter_value() {
  awk -v key="$2" '
    NR == 1 && $0 != "---" { exit 1 }
    NR == 1 { infm = 1; next }
    infm && $0 == "---" { exit 0 }
    infm {
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

# backtick'd file paths must exist; templates/refs are skill-relative
check_references() {
  local file="$1" token target
  local dir; dir=$(dirname "$file")
  # references/templates cite siblings against the skill dir, not itself
  local root="$dir"
  case "$dir" in */references|*/templates) root=$(dirname "$dir") ;; esac
  # process substitution, not a pipeline: warn's counter survives the loop
  # shellcheck disable=SC2016
  while IFS= read -r token; do
    case "$token" in
      agents/*|skills/*|docs/*|scripts/*) target="$token" ;;
      templates/*|references/*) target="$root/$token" ;;
      *) continue ;;
    esac
    case "$token" in  # skip globs / placeholders / anchors
      *'*'*|*'<'*|*'>'*|*'('*|*')'*|*' '*|*'#'*) continue ;;
    esac
    case "$token" in  # must have a known file extension
      *.md|*.sh|*.json|*.yml|*.yaml|*.plist|*.ts|*.tsx) : ;;
      *) continue ;;
    esac
    [ -e "$target" ] || warn "$file references \`$token\` which does not exist"
  done < <(grep -oE '`[^`]+`' "$file" 2>/dev/null | tr -d '`')
}

# a cited heading must exist too, not just the file; a bare one is self-ref
check_heading_refs() {
  local file="$1" pair path heading target h found
  local dir; dir=$(dirname "$file")
  local root="$dir"
  case "$dir" in */references|*/templates) root=$(dirname "$dir") ;; esac
  while IFS= read -r pair; do
    path=${pair%%$'\t'*}; heading=${pair#*$'\t'}
    [ -n "$path" ] && [ -n "$heading" ] || continue
    case "$path" in
      agents/*|skills/*|docs/*|scripts/*) target="$path" ;;
      templates/*|references/*)           target="$root/$path" ;;
      # a bare SKILL.md cited from references/templates means the sibling
      *.md) if [ -e "$dir/$path" ]; then target="$dir/$path"
            else target="$root/$path"; fi ;;
      *) continue ;;
    esac
    [ -e "$target" ] || continue   # check_references already warned on this
    # PREFIX match: house style cites `## Step 3` for `## Step 3 — x`
    found=0
    while IFS= read -r h; do
      if [ "$h" = "$heading" ]; then found=1; break; fi
      if [ "${h:0:${#heading}}" = "$heading" ]; then
        case "${h:${#heading}:1}" in ' '|':'|'—'|'–'|'-') found=1; break ;; esac
      fi
    done < <(grep '^#' "$target" 2>/dev/null)
    [ "$found" -eq 1 ] \
      || warn "$file cites \`$heading\` in $path, which has no such heading"
  done < <(
    # two-backtick form, with an optional arrow between the halves
    grep -oE '`[A-Za-z0-9_./-]+\.md` *(→ *)?`#{2,} [^`]+`' "$file" 2>/dev/null \
      | sed -E 's/`([A-Za-z0-9_./-]+\.md)` *(→ *)?`(#{2,} [^`]+)`/\1\t\3/'
    # one-backtick form
    grep -oE '`[A-Za-z0-9_./-]+\.md #{2,} [^`]+`' "$file" 2>/dev/null \
      | sed -E 's/`([A-Za-z0-9_./-]+\.md) (#{2,} [^`]+)`/\1\t\2/'
  )
}

validate_spec() {
  local file="$1" expected_name="$2" name desc
  if ! has_frontmatter "$file"; then
    err "$file has no frontmatter (must start with \`---\`)"
    return
  fi
  name=$(frontmatter_value "$file" name)
  desc=$(frontmatter_value "$file" description)
  # strip one quote layer: specs mix `name: foo` and `name: "foo"`
  name=${name#[\"\']}; name=${name%[\"\']}
  [ -n "$name" ] || err "$file missing or empty \`name:\`"
  [ -n "$desc" ] || err "$file missing or empty \`description:\`"
  if [ -n "$name" ] && [ "$name" != "$expected_name" ]; then
    err "$file declares name \`$name\` but path implies \`$expected_name\`"
  fi
  check_references "$file"
  check_heading_refs "$file"
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

# no frontmatter here; docs/decisions/ excluded, quotes illustrative paths
for f in skills/*/references/*.md skills/*/templates/*.md docs/*.md; do
  [ -e "$f" ] || continue
  check_references "$f"
  check_heading_refs "$f"
done

# every declared subcommand verb must reach the family doc, or it drifts
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

# every *.test.sh needs a workflow step; derived from the tree, not a list

# emits only real run: shell (inline + block scalar), never a YAML mention
# (a step name, a path filter, a stale TODO) that isn't actually run
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

# every shipped file must resolve via ~/.claude; WARN: local deploy state

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

# a docs/ heading duplicating a skill section is the copy nothing enforces
skill_heads=$(grep -h '^## ' skills/*/SKILL.md 2>/dev/null | sort -u)
for f in docs/*.md docs/decisions/*.md; do
  [ -e "$f" ] || continue
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    if printf '%s\n' "$skill_heads" | grep -qxF "$h"; then
      warn "$f restates a skill section: \`$h\` — the skill is the enforced copy"
    fi
  done < <(grep '^## ' "$f" 2>/dev/null)
done

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
