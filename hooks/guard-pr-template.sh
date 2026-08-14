#!/usr/bin/env bash
# PreToolUse guard for PR bodies (matcher: Bash).
# Denies a `gh pr create` / `gh pr edit` whose body ignores the repo's PR
# template entirely. Everything else passes through untouched.
#
# `looper-commit` `## Step 3` already states the rule, and states it
# correctly. It only loads when a body is written inside a looper-commit
# dispatch — so a body composed by the orchestrator calling `gh` directly
# never sees it, and `gh pr create --body` never prefills a template
# either. That path shipped this repo's PR #55 in the wrong shape. Prose
# in the skill did not reach the actor doing the work; this does.
#
# The bar is deliberately low: ONE of the template's own section markers
# present in the body is enough to pass. This catches "wrote my own
# headings," not "filled it imperfectly" — judging completeness is the
# reviewer's job and a hook that tried would be wrong more often than the
# author.
#
# Fails OPEN everywhere it cannot see clearly: no template, a template
# with no extractable markers, a body it cannot read, a `--repo` pointing
# at a tree that is not here. A guard that blocks on its own blind spots
# is one people route around.

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

# --- Is this a PR body write at all? ------------------------------------
printf '%s' "$cmd" | grep -Eq 'gh +pr +(create|edit)\b' || allow
# No body flag means no body to judge: `gh pr edit --add-label`, or a
# create that will open an editor (where GitHub DOES prefill the template).
printf '%s' "$cmd" | grep -Eq -- '(--body|--body-file|-b|-F)\b' || allow
# A body read from stdin is not on disk to inspect.
printf '%s' "$cmd" | grep -Eq -- '(--body-file|-F)[ =]+-( |$)' && allow
# Targeting another repo: its template is not the one in this tree.
printf '%s' "$cmd" | grep -Eq -- '(--repo|-R)\b' && allow

# --- Find the template --------------------------------------------------
# GitHub honors either casing in three locations. A PULL_REQUEST_TEMPLATE/
# DIRECTORY holds several and auto-applies none, so there is no single
# expected shape to hold a body to.
root=$(git rev-parse --show-toplevel 2>/dev/null) || allow
[ -n "$root" ] || allow
for d in .github docs ""; do
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

# --- The template's own section markers ---------------------------------
# Bold labels (`**Added:**`, including inside a list item) and ATX
# headings. An HTML-comment-only template yields none, and yields no
# verdict either.
markers=$(grep -oE '\*\*[A-Za-z][^*]*:\*\*|^#{1,6} +[^ ].*' "$template" \
          | sed 's/[[:space:]]*$//' | sort -u)
[ -n "$markers" ] || allow

# --- The body being submitted -------------------------------------------
# The command string carries an inline --body verbatim, so it is already
# half the haystack. A --body-file's CONTENTS are the other half.
haystack=$cmd
path=$(printf '%s' "$cmd" \
       | grep -oE -- '(--body-file|-F)[ =]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^ ]+)' \
       | head -1 | sed -E 's/^(--body-file|-F)[ =]+//; s/^["'"'"']//; s/["'"'"']$//')
if [ -n "$path" ]; then
  # The command has not run yet, so `$TMPDIR/body.md` is still literal.
  # Expand plain $VAR / ${VAR} from the hook's own environment. Never
  # $( ) or backticks — expanding those would RUN whatever the command
  # embedded, from a hook that exists to inspect it.
  case "$path" in
    *'$('*|*'`'*) allow ;;
    *'$'*)
      # UNSET is a literal sentinel, not a NUL: bash strings cannot hold
      # a NUL, so `$'\0'` is the empty string and a `*$'\0'*` test is
      # `**`, which matches every path and blanks all of them.
      path=$(printf '%s' "$path" \
             | perl -pe 's/\$\{(\w+)\}/exists $ENV{$1} ? $ENV{$1} : "\x01UNSET"/ge;
                          s/\$(\w+)/exists $ENV{$1} ? $ENV{$1} : "\x01UNSET"/ge' 2>/dev/null)
      # A name this process cannot see is a body it cannot read.
      case "$path" in *$'\x01'UNSET*) allow ;; esac ;;
  esac
  case "$path" in /*) : ;; *) path="$root/$path" ;; esac
  # An unreadable path means the body is invisible, not that it is wrong.
  [ -f "$path" ] || allow
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
