#!/usr/bin/env bash
# custodian-skill-lint — self-contained SKILL.md linter for the looper skills.
#
# Ports the published Agent Skills spec lint schemas into pure bash + awk + grep
# — no third-party tools, no tokenizer deps (`[[no-third-party-hosted-tool-reliance]]`:
# mine the check tables, don't adopt the linters). Runs over this repo's tracked
# `skills/` tree (and root context files) and, as a propose-only custodian signal,
# routes structural findings into Phase B of the weekly run. It never edits a file.
#
# ── Provenance of the checked rules ────────────────────────────────────────────
# Frontmatter schema + budgets are the Agent Skills open standard, fetched from
# https://agentskills.io/specification on 2026-07-27 (corroborated by the Claude
# Code skills docs). The canonical rules encoded below:
#   required frontmatter:  name, description
#   optional frontmatter:  license, compatibility, metadata, allowed-tools  (exactly 4)
#   name:         1-64 chars, lowercase a-z/0-9/hyphen, no leading/trailing/`--`, == dir
#   description:  1-1024 chars, non-empty
#   compatibility: <=500 chars if present
#   progressive disclosure budgets (ADVISORY): ~100-token discovery (name+description),
#     <5000-token activation body (recommended), keep SKILL.md <500 lines, reference
#     files small, AGENTS.md/CLAUDE.md context files kept lean (<150 lines, converged
#     community guidance).
# The full Phase E research artifacts backing this port are under
# local/custodian/2026-07-27/ (issue #29, finding E-1).
#
# ── Two tiers ──────────────────────────────────────────────────────────────────
# STRUCTURAL (violations, exit 1): frontmatter allowlist + required fields, name
#   pattern/length/dir-match, empty/over-length description, broken internal links
#   (relative file refs + intra-skill `[[wiki-links]]`), reference nesting deeper
#   than one level, and a false-positive-averse secret-leak scan.
# ADVISORY (INFO, exit stays 0): the token/line budgets above. Token counts are
#   APPROXIMATE — chars/4, the standard rough BPE proxy (see `est_file_tokens`).
#   For markdown/code-ish prose the real BPE tokenizer runs slightly HOTTER than
#   chars/4 (shorter sub-word tokens), so this proxy UNDER-reports — anything it
#   flags as over-budget is over-budget for real (conservative in the flag
#   direction); it may miss a marginal case, which is fine for an advisory. These
#   findings inform EXTRACTION decisions (split a fat body into references), never
#   prose smoothing — the looper's war-story prose is deliberate (project memory
#   `[[project-skill-slimming-yields]]`). They are NEVER violations and never
#   change the exit code.
#
# Description checks are strictly MECHANICAL (present, length bounds, first-person
# opener, a trigger-cue presence heuristic) — no editorial judgement, and edits
# are out of scope: the linter reports, a human disposes.
#
# Mirrors scripts/custodian-history.sh conventions: set -euo pipefail, env-override
# paths, subcommand dispatch, usage-on-stderr exit 2. Grep/awk that may legitimately
# return non-zero (no match) are guarded so pipefail never turns a clean scan fatal.
#
# Usage:
#   custodian-skill-lint.sh [lint] [<skill-dir|SKILL.md|context.md> ...]
#     no path args ⇒ lints every skills/<name>/ plus root CLAUDE.md/AGENTS.md.
#   custodian-skill-lint.sh -h | --help
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SKILLS_ROOT="${SKILLS_ROOT:-$REPO_ROOT/skills}"

# --- Spec constants (agentskills.io/specification, 2026-07-27) ---
NAME_MAX=64
DESC_MAX=1024
COMPAT_MAX=500
REQUIRED_FIELDS="name description"
OPTIONAL_FIELDS="license compatibility metadata allowed-tools"

# --- Advisory budgets (approximate; chars/4 token proxy) ---
DISCOVERY_TOKEN_BUDGET=100     # name + description at startup
BODY_TOKEN_BUDGET=5000         # full SKILL.md when activated (recommended ceiling)
BODY_LINE_BUDGET=500           # spec: keep SKILL.md under 500 lines
REFERENCE_TOKEN_BUDGET=5000    # keep references/ files focused (loaded on demand)
CONTEXT_LINE_BUDGET=150        # AGENTS.md/CLAUDE.md context files

violations=0
advisories=0

viol() { printf 'VIOLATION %-22s %s: %s\n' "$1" "$2" "$3"; violations=$((violations + 1)); }
info() { printf 'INFO      %-22s %s: %s\n' "$1" "$2" "$3"; advisories=$((advisories + 1)); }

# --- Token estimate: chars/4, the standard rough BPE proxy (see header note) ---
est_file_tokens() { # file -> approx token count
  local c; c=$(wc -c < "$1" 2>/dev/null | tr -d ' '); echo $(( ${c:-0} / 4 )); }
est_str_tokens() { echo $(( ${#1} / 4 )); }

# --- Frontmatter helpers (block between the first two `---` fences) ---
has_frontmatter() { [ "$(head -n 1 "$1" 2>/dev/null)" = "---" ]; }

# Top-level frontmatter keys, one per line. Column-0 `key:` only, so nested
# entries under `metadata:` (indented) are correctly ignored.
frontmatter_keys() {
  awk '
    NR == 1 && $0 != "---" { exit }
    NR == 1 { next }
    $0 == "---" { exit }
    /^[A-Za-z0-9_-]+:/ { k = $0; sub(/:.*/, "", k); print k }
  ' "$1" 2>/dev/null || true
}

# Scalar value of a top-level key (first line only — the repo uses single-line
# scalars; a folded/block scalar would be under-measured, acceptable for a lint).
frontmatter_value() {
  awk -v key="$2" '
    NR == 1 && $0 != "---" { exit }
    NR == 1 { next }
    $0 == "---" { exit }
    $0 ~ "^" key ":[[:space:]]*" { sub("^" key ":[[:space:]]*", ""); print; exit }
  ' "$1" 2>/dev/null || true
}

in_list() { # needle list...
  local needle="$1"; shift
  local x
  for x in $1; do [ "$x" = "$needle" ] && return 0; done
  return 1
}

# --- Internal-link extraction: markdown `](target)` + bare subdir path tokens ---
extract_refs() { # file -> candidate relative refs, one per line
  local file="$1"
  { grep -oE '\]\([^)]+\)' "$file" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//'
    grep -oE '(references|scripts|assets|templates)/[A-Za-z0-9._/-]+' "$file" 2>/dev/null
  } || true
}

# Resolve a relative ref against a base dir, returning 0 + echoing the path when
# it names an EXISTING file inside the skill dir. Skips URLs, anchors, absolute /
# home paths, `../` escapes, and glob/placeholder tokens.
resolve_ref() { # base_dir skill_dir ref -> echoes resolved path, rc 0 if exists within skill
  local base="$1" skill="$2" ref="$3" target
  ref="${ref%%#*}"                      # drop any #anchor
  [ -n "$ref" ] || return 1
  case "$ref" in
    http://*|https://*|mailto:*|/*|'~'*|'#'*) return 1 ;;
    ../*|*/../*) return 1 ;;
    *' '*|*'*'*|*'<'*|*'>'*|*'('*|*'$'*) return 1 ;;
  esac
  target="$base/$ref"
  case "$target" in "$skill"/*|"$skill") : ;; *) return 1 ;; esac
  [ -f "$target" ] && { echo "$target"; return 0; }
  return 1
}

# --- Secret-leak scan: well-known key/token shapes + credential home paths only,
#     kept deliberately narrow so ordinary prose (and `~/.claude/...` tildes) never
#     trips it. name<TAB>regex pairs. ---
secret_scan() { # file
  local file="$1" name regex ln
  local patterns=(
    "aws-access-key"     'AKIA[0-9A-Z]{16}'
    "github-token"       'gh[oprsu]_[A-Za-z0-9]{36,}'
    "github-pat"         'github_pat_[A-Za-z0-9_]{40,}'
    "anthropic-key"      'sk-ant-[A-Za-z0-9_-]{20,}'
    "openai-key"         'sk-[A-Za-z0-9]{20,}'
    "slack-token"        'xox[baprs]-[A-Za-z0-9-]{10,}'
    "google-api-key"     'AIza[0-9A-Za-z_-]{35}'
    "private-key-header" '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    "credential-path"    '(/Users/|/home/)[^ ]*/(\.ssh/|\.aws/credentials|id_rsa|id_ed25519|\.env($|[^A-Za-z]))'
  )
  local i=0
  while [ "$i" -lt "${#patterns[@]}" ]; do
    name="${patterns[$i]}"; regex="${patterns[$((i + 1))]}"; i=$((i + 2))
    while IFS= read -r ln; do
      [ -n "$ln" ] || continue
      viol "secret-leak" "$file:$ln" "matches $name pattern"
    done < <(grep -nE "$regex" "$file" 2>/dev/null | cut -d: -f1 || true)
  done
}

# --- Lint one skill directory ---
lint_skill() {
  local dir="$1"
  dir="${dir%/}"
  local skill; skill=$(basename "$dir")
  local f="$dir/SKILL.md"

  if [ ! -f "$f" ]; then
    viol "frontmatter-missing" "$dir" "no SKILL.md in skill directory"
    return
  fi
  if ! has_frontmatter "$f"; then
    viol "frontmatter-missing" "$f" "must start with a \`---\` frontmatter fence"
    return
  fi

  # Frontmatter allowlist + required fields.
  local key seen_name=0 seen_desc=0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    [ "$key" = "name" ] && seen_name=1
    [ "$key" = "description" ] && seen_desc=1
    if ! in_list "$key" "$REQUIRED_FIELDS $OPTIONAL_FIELDS"; then
      viol "frontmatter-unknown-field" "$f" "\`$key\` is not in the spec allowlist (name/description + license/compatibility/metadata/allowed-tools)"
    fi
  done < <(frontmatter_keys "$f")
  [ "$seen_name" -eq 1 ] || viol "frontmatter-required" "$f" "missing required \`name:\`"
  [ "$seen_desc" -eq 1 ] || viol "frontmatter-required" "$f" "missing required \`description:\`"

  # name: pattern / length / dir match.
  local name; name=$(frontmatter_value "$f" name)
  name="${name#[\"\']}"; name="${name%[\"\']}"
  if [ -n "$name" ]; then
    [ "${#name}" -le "$NAME_MAX" ] || viol "name-length" "$f" "name is ${#name} chars (max $NAME_MAX)"
    if ! printf '%s' "$name" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' || printf '%s' "$name" | grep -q -- '--'; then
      viol "name-pattern" "$f" "name \`$name\` must be lowercase a-z/0-9/hyphen, no leading/trailing or consecutive hyphens"
    fi
    [ "$name" = "$skill" ] || viol "name-mismatch" "$f" "name \`$name\` does not match directory \`$skill\`"
  fi

  # description: presence / length (structural); opener + trigger-cue (advisory).
  local desc; desc=$(frontmatter_value "$f" description)
  desc="${desc#[\"\']}"; desc="${desc%[\"\']}"
  if [ -z "$desc" ]; then
    [ "$seen_desc" -eq 1 ] && viol "description-empty" "$f" "\`description:\` is present but empty"
  else
    [ "${#desc}" -le "$DESC_MAX" ] || viol "description-length" "$f" "description is ${#desc} chars (max $DESC_MAX)"
    case "$desc" in
      I\ *|I\'*) info "adv-description-firstperson" "$f" "description opens first-person (\"I …\") — lead with the capability" ;;
    esac
    if ! printf '%s' "$desc" | grep -qiE 'when|use this|trigger|invoke'; then
      info "adv-description-trigger" "$f" "description has no obvious usage/trigger cue (when to invoke)"
    fi
    local disc_tok; disc_tok=$(( $(est_str_tokens "$name") + $(est_str_tokens "$desc") ))
    [ "$disc_tok" -le "$DISCOVERY_TOKEN_BUDGET" ] || info "adv-discovery-budget" "$f" "name+description ~${disc_tok} tokens > ${DISCOVERY_TOKEN_BUDGET} discovery budget"
  fi

  # compatibility length (if present).
  local compat; compat=$(frontmatter_value "$f" compatibility)
  compat="${compat#[\"\']}"; compat="${compat%[\"\']}"
  if [ -n "$compat" ]; then
    [ "${#compat}" -le "$COMPAT_MAX" ] || viol "compatibility-length" "$f" "compatibility is ${#compat} chars (max $COMPAT_MAX)"
  fi

  # Body budgets (advisory).
  local btok blines
  btok=$(est_file_tokens "$f")
  blines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
  [ "$btok" -le "$BODY_TOKEN_BUDGET" ] || info "adv-body-budget" "$f" "body ~${btok} tokens > ${BODY_TOKEN_BUDGET} (consider extracting to references/ — informs extraction, not prose smoothing)"
  [ "${blines:-0}" -le "$BODY_LINE_BUDGET" ] || info "adv-body-lines" "$f" "${blines} lines > ${BODY_LINE_BUDGET} recommended"

  # Broken internal links from SKILL.md. Only refs into a subdir the skill
  # actually BUNDLES (references/ templates/ assets/ scripts/) are in-scope — a
  # `scripts/foo.sh` when the skill has no scripts/ dir is a REPO-relative
  # reference (the repo's own scripts/), out of scope for the intra-skill check
  # and already covered by validate-looper-config.sh. Scoping on subdir existence
  # is what keeps that distinction false-positive-averse.
  local ref seg
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in
      references/*|scripts/*|assets/*|templates/*) ;;
      *) continue ;;
    esac
    seg="${ref%%/*}"
    [ -d "$dir/$seg" ] || continue   # subdir not bundled here → repo/external ref
    resolve_ref "$dir" "$dir" "$ref" >/dev/null || viol "broken-link" "$f" "reference \`$ref\` does not resolve to a file in the skill"
  done < <(extract_refs "$f")

  # Intra-skill [[wiki-links]]: only validated when the skill actually uses them
  # locally (>=1 slug resolves to a same-skill file). Cross-scope memory `[[links]]`
  # — which never resolve inside the skill dir — stay out of scope, so real looper
  # skills (all memory-style links) are never false-flagged.
  local slug resolved=0 total=0 slugs
  slugs=$(grep -oE '\[\[[A-Za-z0-9._-]+\]\]' "$f" 2>/dev/null | sed -E 's/^\[\[//; s/\]\]$//' || true)
  if [ -n "$slugs" ]; then
    while IFS= read -r slug; do
      [ -n "$slug" ] || continue
      total=$((total + 1))
      if [ -f "$dir/$slug.md" ] || [ -f "$dir/references/$slug.md" ] || [ -f "$dir/$slug" ]; then
        resolved=$((resolved + 1))
      fi
    done < <(printf '%s\n' "$slugs")
    if [ "$resolved" -gt 0 ]; then
      while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        if [ ! -f "$dir/$slug.md" ] && [ ! -f "$dir/references/$slug.md" ] && [ ! -f "$dir/$slug" ]; then
          viol "broken-link" "$f" "intra-skill link \`[[$slug]]\` resolves to no file in the skill"
        fi
      done < <(printf '%s\n' "$slugs")
    fi
  fi

  # references/ files: budget (advisory) + one-level nesting (structural).
  if [ -d "$dir/references" ]; then
    local rf rtok r target
    for rf in "$dir/references"/*; do
      [ -f "$rf" ] || continue
      rtok=$(est_file_tokens "$rf")
      [ "$rtok" -le "$REFERENCE_TOKEN_BUDGET" ] || info "adv-reference-budget" "$rf" "reference ~${rtok} tokens > ${REFERENCE_TOKEN_BUDGET} — keep reference files focused"
      # A reference file that itself links to another existing skill-local file is
      # a second-level chain (deeper than one level from SKILL.md).
      while IFS= read -r r; do
        [ -n "$r" ] || continue
        if target=$(resolve_ref "$(dirname "$rf")" "$dir" "$r"); then
          [ "$target" = "$rf" ] && continue
          viol "reference-nesting" "$rf" "references \`$r\` — reference chains must stay one level deep from SKILL.md"
        elif target=$(resolve_ref "$dir" "$dir" "$r"); then
          [ "$target" = "$rf" ] && continue
          viol "reference-nesting" "$rf" "references \`$r\` — reference chains must stay one level deep from SKILL.md"
        fi
      done < <(extract_refs "$rf")
    done
  fi

  # Secret scan across the skill's text files.
  local tf
  while IFS= read -r tf; do
    [ -n "$tf" ] || continue
    secret_scan "$tf"
  done < <(find "$dir" -type f \( -name '*.md' -o -name '*.sh' -o -name '*.txt' -o -name '*.json' -o -name '*.yml' -o -name '*.yaml' \) 2>/dev/null || true)
}

# --- Lint a context file (AGENTS.md / CLAUDE.md): advisory line budget + secrets ---
lint_context() {
  local f="$1" lines
  [ -f "$f" ] || return 0
  lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
  [ "${lines:-0}" -le "$CONTEXT_LINE_BUDGET" ] || info "adv-context-lines" "$f" "${lines} lines > ${CONTEXT_LINE_BUDGET} recommended for a context file"
  secret_scan "$f"
}

# Dispatch a path arg to the right linter.
lint_path() {
  local p="$1"
  if [ -d "$p" ]; then
    lint_skill "$p"
  elif [ -f "$p" ]; then
    case "$(basename "$p")" in
      SKILL.md) lint_skill "$(dirname "$p")" ;;
      CLAUDE.md|AGENTS.md) lint_context "$p" ;;
      *) lint_context "$p" ;;   # treat any other file as a context/prose file
    esac
  else
    viol "path-missing" "$p" "no such file or directory"
  fi
}

run_lint() {
  violations=0; advisories=0
  if [ "$#" -gt 0 ]; then
    local p
    for p in "$@"; do lint_path "$p"; done
  else
    local d
    for d in "$SKILLS_ROOT"/*/; do
      [ -d "$d" ] || continue
      lint_skill "$d"
    done
    lint_context "$REPO_ROOT/CLAUDE.md"
    lint_context "$REPO_ROOT/AGENTS.md"
  fi
  printf '\n--- skill-lint summary ---\n'
  printf 'structural violations: %d\n' "$violations"
  printf 'advisory findings: %d\n' "$advisories"
  printf 'TOTAL VIOLATIONS: %d\n' "$violations"
  [ "$violations" -eq 0 ]
}

usage() {
  echo "usage: $0 [lint] [<skill-dir|SKILL.md|context.md> ...]" >&2
  echo "  no path args ⇒ lints skills/<name>/ + root CLAUDE.md/AGENTS.md" >&2
  echo "  structural violations ⇒ exit 1; advisory-only ⇒ exit 0" >&2
}

cmd="${1:-lint}"
case "$cmd" in
  lint)      shift || true; run_lint "$@" ;;
  -h|--help) usage; exit 0 ;;
  --*)       echo "unknown flag: $cmd" >&2; usage; exit 2 ;;
  *)         run_lint "$@" ;;   # bare paths ⇒ lint them
esac
