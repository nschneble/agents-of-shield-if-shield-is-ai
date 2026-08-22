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
#   (relative file refs + intra-skill `[[wiki-links]]`), a reference FILE nested
#   deeper than one level (references/a/b/c.md), and a false-positive-averse
#   secret-leak scan.
# ADVISORY (INFO, exit stays 0): the token/line budgets above, plus one reference
#   file CROSS-LINKING another (`adv-reference-chain`) — a prose mention, not a
#   load path, so it is an extraction judgement like the budgets, while the
#   depth check above measures a path fact (docs/decisions/looper-custodian.md decision 29).
#   Token counts are APPROXIMATE — chars/4, the standard rough BPE proxy (see
#   `est_file_tokens`).
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
# ── Known limitations ───────────────────────────────────────────────────────────
# A `[[wiki-link]]` shown inside a fenced code block is NOT exempted from the
# intra-skill link check — a documented example slug is resolved like a live link.
# Not worth a fence parser for a hypothetical; noted so a future false positive is
# understood, not chased. (Frontmatter scalars are read single-line only — see the
# `frontmatter_value` note.)
#
# Mirrors scripts/custodian-history.sh conventions: set -euo pipefail, env-override
# paths, subcommand dispatch, usage-on-stderr exit 2. Grep/awk that may legitimately
# return non-zero (no match) are guarded so pipefail never turns a clean scan fatal.
#
# Usage:
#   custodian-skill-lint.sh [lint] [<skill-dir|SKILL.md|context.md> ...]
#     no path args ⇒ lints every skills/<name>/ plus root CLAUDE.md/AGENTS.md if present.
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

# True (rc 0) when a closing column-0 `---` fence exists after the opening one.
# Without it the frontmatter block is unterminated: the key/value awk below would
# run to EOF and misread body lines as keys (either silently — a prose body has no
# `key:` lines so the file passes clean — or as a misleading unknown-field cascade
# when body lines like `Example:`/`Note:` look like keys). Callers assert this
# before any key parsing and emit `frontmatter-unterminated` when it fails.
frontmatter_terminated() { # file
  awk '
    NR == 1 { next }              # opener already checked by has_frontmatter
    $0 == "---" { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$1" 2>/dev/null
}

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

# --- Internal-link extraction: markdown `](target)`, bare subdir path tokens,
#     and bare filenames ---
# A bare token is only skill-relative when it STARTS a path. Three
# spellings start one: line start, after a non-path character, and after
# the token's own `./`. A fully qualified cite carries `references/…` as
# a TAIL, and reading that as skill-relative names another skill's file
# as this skill's own — silent until a skill both bundles references/
# and cites another skill's reference by full path. So the prefix
# decides ownership instead of being ignored: `skills/<this-skill>/` is
# stripped (the remainder IS skill-relative), any other skill's prefix
# drops the token. `../` is matched and passed to resolve_ref, which
# rejects a parent escape on its own terms — a visible rejection beats a
# silent non-match.
BARE_REF_RE='(^|[^A-Za-z0-9._/-])(skills/[A-Za-z0-9._-]+/)?(\.\.?/)?(references|scripts|assets|templates)/[A-Za-z0-9._/-]+'

# A bare-filename cite names the same file as the qualified spelling, but
# BARE_REF_RE keys on the path segment and cannot see it — one chain, two
# answers, decided by typing. Same leading-delimiter guard, which is what keeps
# the TAIL of `skills/other/references/x.md` from re-reading as a local cite.
# No extension allowlist: resolve is the filter, so an `e.g` costs one lookup.
BARE_FILE_RE='(^|[^A-Za-z0-9._/-])(\./)?[A-Za-z0-9_-][A-Za-z0-9._-]*\.[A-Za-z0-9]+'

# Normalize raw BARE_REF_RE matches on stdin into skill-relative refs.
# Dropping one leading delimiter is unambiguous because `.` `_` `-` `/`
# and the alphanumerics are all IN the path class, so a delimiter is
# never `.` and a line-start match (which opens on a letter or a `.`) is
# left alone. The own-skill test is a string compare, so a skill name
# needs no regex escaping.
skill_relative_refs() { # skill_name  (stdin: raw matches, stdout: refs)
  awk -v own="$1" '
    { sub(/^[^A-Za-z.]/, "") }
    /^skills\// {
      if (index($0, "skills/" own "/") != 1) next
      sub(/^skills\/[^\/]+\//, "")
    }
    { sub(/^\.\//, ""); print }
  '
}

# `sort -u` because `[b](b.md)` now matches two greps and would count twice.
# The strip class keeps `.`, unlike skill_relative_refs': a line-start `./b.md`
# match opens on the dot, and stripping it would leave `/b.md`.
extract_refs() { # skill_dir file -> candidate relative refs, deduped, one per line
  local dir="${1%/}" file="$2" skill
  skill=$(basename "$dir")
  { grep -oE '\]\([^)]+\)' "$file" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//'
    grep -oE "$BARE_REF_RE" "$file" 2>/dev/null | skill_relative_refs "$skill"
    grep -oE "$BARE_FILE_RE" "$file" 2>/dev/null | sed -E 's/^[^A-Za-z0-9._-]//; s/^\.\///'
  } | sort -u || true
}

# --- In-scope refs for the broken-link check (deduped) ---
# Markdown `](target)` links are ALWAYS in scope: an explicit intra-skill link
# whose target is missing is the violation regardless of whether the subdir
# exists — that is what makes a dangling `](references/gone.md)` a violation even
# with no references/ dir present. Bare path tokens found in prose are in scope
# only when the skill actually BUNDLES that subdir; otherwise they are
# repo-relative mentions (e.g. the repo's own scripts/), out of scope here and
# already covered by validate-looper-config.sh. `sort -u` collapses a target that
# appears as BOTH a markdown link and a matching bare token (the two greps both
# match on one line) to a single ref, so one broken link is counted exactly once.
scoped_refs() { # skill_dir file -> in-scope relative refs, deduped, one per line
  local dir="${1%/}" file="$2" bref seg skill
  skill=$(basename "$dir")
  {
    grep -oE '\]\([^)]+\)' "$file" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//'
    while IFS= read -r bref; do
      [ -n "$bref" ] || continue
      seg="${bref%%/*}"
      [ -d "$dir/$seg" ] && printf '%s\n' "$bref"
    done < <(grep -oE "$BARE_REF_RE" "$file" 2>/dev/null \
               | skill_relative_refs "$skill" || true)
  } | sort -u || true
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

  # Classify the frontmatter WITHOUT early-returning. A malformed block (missing
  # SKILL.md, missing opening fence, or no closing fence) only disables the checks
  # that need PARSED frontmatter keys. Every frontmatter-INDEPENDENT scan below
  # (body/link/wiki-link, reference nesting, and — critically — the secret scan)
  # must still run, so a broken fence in one skill can never silence a security
  # scan across that skill's own files and references.
  local fm_ok=1
  if [ ! -f "$f" ]; then
    viol "frontmatter-missing" "$dir" "no SKILL.md in skill directory"
    fm_ok=0
  elif ! has_frontmatter "$f"; then
    viol "frontmatter-missing" "$f" "must start with a \`---\` frontmatter fence (if the fence looks present, check for a leading BOM or CRLF line endings)"
    fm_ok=0
  elif ! frontmatter_terminated "$f"; then
    # A closing `---` must exist before we treat any body line as a key, or an
    # unterminated block either passes silently or cascades bogus unknown-field
    # findings that never name the real fault. Flag it and skip the key parse.
    viol "frontmatter-unterminated" "$f" "opened with \`---\` but has no closing \`---\` fence — body lines cannot be parsed as frontmatter keys"
    fm_ok=0
  fi

  # ── Frontmatter-DEPENDENT checks: run only when the block parses cleanly ──────
  if [ "$fm_ok" -eq 1 ]; then
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
  fi

  # ── Frontmatter-INDEPENDENT checks: run regardless of a malformed fence ───────

  # Body/link/wiki scans read SKILL.md directly (no parsed keys), so they cover a
  # malformed-but-present fence too — they only need the file itself to exist.
  if [ -f "$f" ]; then
    # Body budgets (advisory).
    local btok blines
    btok=$(est_file_tokens "$f")
    blines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    [ "$btok" -le "$BODY_TOKEN_BUDGET" ] || info "adv-body-budget" "$f" "body ~${btok} tokens > ${BODY_TOKEN_BUDGET} (consider extracting to references/ — informs extraction, not prose smoothing)"
    [ "${blines:-0}" -le "$BODY_LINE_BUDGET" ] || info "adv-body-lines" "$f" "${blines} lines > ${BODY_LINE_BUDGET} recommended"

    # Broken internal links from SKILL.md. scoped_refs decides scope per ref: a
    # markdown `](target)` link is an explicit intra-skill link (in scope even
    # when the subdir is absent — a dangling target is the violation), while a
    # bare `scripts/foo.sh` prose token with no bundled scripts/ dir is a
    # REPO-relative reference (the repo's own scripts/), out of scope here and
    # already covered by validate-looper-config.sh. The refs arrive deduped, so a
    # single broken link surfaces exactly once.
    local ref
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      case "$ref" in
        references/*|scripts/*|assets/*|templates/*) ;;
        *) continue ;;
      esac
      resolve_ref "$dir" "$dir" "$ref" >/dev/null || viol "broken-link" "$f" "reference \`$ref\` does not resolve to a file in the skill"
    done < <(scoped_refs "$dir" "$f")

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
  fi

  # references/ files: budget (advisory) + one-level nesting (structural). Operates
  # on the references/ dir, so it needs no SKILL.md and runs for a malformed skill.
  # Walk the tree with `find` (recursive) rather than a `references/*` glob: the
  # glob only matched DIRECT children, so a file physically nested in a subdir
  # (references/a/b/c.md) was never scanned and the depth predicate never fired.
  if [ -d "$dir/references" ]; then
    local rf rtok r target rel
    while IFS= read -r rf; do
      [ -n "$rf" ] || continue
      rtok=$(est_file_tokens "$rf")
      [ "$rtok" -le "$REFERENCE_TOKEN_BUDGET" ] || info "adv-reference-budget" "$rf" "reference ~${rtok} tokens > ${REFERENCE_TOKEN_BUDGET} — keep reference files focused"
      # Directory-depth nesting: a reference file must be a DIRECT child of
      # references/ (one level from SKILL.md). A file inside a subdirectory
      # (references/a/b/c.md → rel `a/b/c.md`) is nested deeper than one level.
      rel="${rf#"$dir/references/"}"
      case "$rel" in
        */*) viol "reference-nesting" "$rf" "reference file is nested at \`references/$rel\` — reference files must stay one level deep from SKILL.md" ;;
      esac
      # Cross-links between reference files: ADVISORY (decision 29). Every
      # spelling reaches ONE predicate — sibling-relative, then skill root — so
      # `b.md` and `references/b.md` get the same answer. Confined to targets
      # inside references/ because a cite resolving to SKILL.md points UP,
      # which is depth zero; the old skill-root arm called those chains.
      while IFS= read -r r; do
        [ -n "$r" ] || continue
        target=$(resolve_ref "$(dirname "$rf")" "$dir" "$r") \
          || target=$(resolve_ref "$dir" "$dir" "$r") || continue
        [ "$target" = "$rf" ] && continue
        case "$target" in "$dir"/references/*) ;; *) continue ;; esac
        info "adv-reference-chain" "$rf" "cites sibling reference \`$r\` — a reader following it loads two files where one was expected"
      done < <(extract_refs "$dir" "$rf")
    done < <(find "$dir/references" -type f 2>/dev/null || true)
  fi

  # Secret scan across the skill's text files. Runs LAST and unconditionally —
  # even with a missing or unterminated SKILL.md — so a malformed frontmatter can
  # never suppress a credential finding anywhere in the skill directory.
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
  echo "  no path args ⇒ lints skills/<name>/ + root CLAUDE.md/AGENTS.md if present" >&2
  echo "  structural violations ⇒ exit 1; advisory-only ⇒ exit 0" >&2
}

cmd="${1:-lint}"
case "$cmd" in
  lint)      shift || true; run_lint "$@" ;;
  -h|--help) usage; exit 0 ;;
  --*)       echo "unknown flag: $cmd" >&2; usage; exit 2 ;;
  *)         run_lint "$@" ;;   # bare paths ⇒ lint them
esac
