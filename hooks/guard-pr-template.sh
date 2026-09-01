#!/usr/bin/env bash
# PreToolUse guard (Bash): denies a gh pr create/edit whose body ignores
# the repo's PR template entirely (PR #55 shipped in the wrong shape via
# a path looper-commit's own rule never reached). Bar is low: ONE marker
# passes. Fails OPEN wherever unclear: no template, unreadable body, etc

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
[ -n "$cwd" ] && [ -d "$cwd" ] && cd "$cwd" 2>/dev/null

allow() { exit 0; }

deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# --- is this a PR body write at all? ---
printf '%s' "$cmd" | grep -Eq 'gh +pr +(create|edit)\b' || allow
# no body flag: GitHub's own editor prefills the template for a bare create
printf '%s' "$cmd" | grep -Eq -- '(--body|--body-file|-b|-F)\b' || allow
printf '%s' "$cmd" | grep -Eq -- '(--body-file|-F)[ =]+-( |$)' && allow  # stdin body: unreadable
printf '%s' "$cmd" | grep -Eq -- '(--repo|-R)\b' && allow  # another repo, another template

# --- find the template: GitHub honors either casing in three locations ---
root=$(git rev-parse --show-toplevel 2>/dev/null) || allow
[ -n "$root" ] || allow
for d in .github docs ""; do  # a TEMPLATE/ dir holds several; none auto-applies
  [ -d "$root/${d:+$d/}PULL_REQUEST_TEMPLATE" ] && allow
  [ -d "$root/${d:+$d/}pull_request_template" ] && allow
done
template=""
for d in .github docs ""; do
  for n in PULL_REQUEST_TEMPLATE.md pull_request_template.md; do
    p="$root/${d:+$d/}$n"
    [ -f "$p" ] && { template="$p"; break 2; }
  done
done
[ -n "$template" ] || allow

# bold labels + ATX headings; comment-only template yields no verdict
markers=$(grep -oE '\*\*[A-Za-z][^*]*:\*\*|^#{1,6} +[^ ].*' "$template" \
          | sed 's/[[:space:]]*$//' | sort -u)
[ -n "$markers" ] || allow

# --- the body: --body is in $cmd; a --body-file adds its contents ---
haystack=$cmd
path=$(printf '%s' "$cmd" \
       | grep -oE -- '(--body-file|-F)[ =]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^ ]+)' \
       | head -1 | sed -E 's/^(--body-file|-F)[ =]+//; s/^["'"'"']//; s/["'"'"']$//')
if [ -n "$path" ]; then
  # never expand $()/backticks: that would RUN what the command embedded
  case "$path" in
    *'$('*|*'`'*) allow ;;
    *'$'*)
      # sentinel, not NUL: a NUL test would match and blank all paths
      path=$(printf '%s' "$path" \
             | perl -pe 's/\$\{(\w+)\}/exists $ENV{$1} ? $ENV{$1} : "\x01UNSET"/ge;
                          s/\$(\w+)/exists $ENV{$1} ? $ENV{$1} : "\x01UNSET"/ge' 2>/dev/null)
      case "$path" in *$'\x01'UNSET*) allow ;; esac ;;  # unseen name, unreadable body
  esac
  case "$path" in /*) : ;; *) path="$root/$path" ;; esac
  [ -f "$path" ] || allow  # unreadable path: invisible, not wrong
  haystack="$haystack
$(cat "$path" 2>/dev/null)"
fi

# --- Verdict ------------------------------------------------------------
while IFS= read -r m; do
  [ -n "$m" ] || continue
  case "$haystack" in *"$m"*) allow ;; esac
done <<EOF
$markers
EOF

rel=${template#"$root"/}
deny "Blocked by guard: this PR body uses none of $rel's sections. Read that file and fill ITS sections in ITS order, honoring its inline comments (skip empty sections), then retry. Budgets are in skills/looper-commit/templates/pr-guidelines.md: summary under 2 sentences, one line per change, and '## Additional notes' stays out unless it carries a fact the reviewer cannot get from the diff, the tests, or CI."
