#!/usr/bin/env bash
# PreToolUse guard for autonomous looper runs (matcher: Bash).
# Hard-blocks commands that can rewrite history, do irreversible remote
# actions, mass-delete files, or read secrets — regardless of flag order.
# Everything else passes through to the normal permission system.
#
# Decisions are "deny" (not "ask"): an unattended loop must not be able to
# approve these. Run such a command yourself with `!<command>` if intended.
#
# The rules match a SCAN STRING, not the raw command. The scan string drops
# text that is data rather than execution — heredoc bodies and quoted prose
# — because matching those denied commit messages and PR bodies that merely
# NAMED a blocked verb, and blocked grepping for the phrase at all.
# Stripping is skipped wherever the shell would still execute that text, so
# the evasion cases below stay blocked. See ## Scan string.

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

# --- Scan string --------------------------------------------------------
# Anything that EXECUTES a string or heredoc argument. When one of these is
# present the text is code, not data, so nothing is stripped and the raw
# command is matched exactly as it always was. Command substitution counts:
# $(...) and backticks run their contents.
interp='(^|[;&|(]| )(sudo +)?(bash|sh|zsh|dash|fish|ksh|eval|exec|source|xargs|ssh|python3?|node|perl|ruby|php|awk)\b'
subst='\$\(|`'

scan=$cmd

# Heredoc bodies are stdin data (git commit -F -, gh pr create --body
# "$(cat <<EOF)") — except when fed straight to an interpreter, where the
# body IS the script.
if ! printf '%s' "$cmd" | grep -Eq '(bash|sh|zsh|dash|fish|ksh|python3?|node|perl|ruby|php) *<<'; then
  scan=$(printf '%s' "$scan" | perl -0777 -pe 's/<<-?[ \t]*(["'\'']?)(\w+)\1.*?^[ \t]*\2[ \t]*$//gms')
fi

# Collapse whitespace so flags split across spacing still match.
scan=$(printf '%s' "$scan" | tr -s '[:space:]' ' ')

# Quoted arguments, only when no interpreter or substitution is in play.
# A single-word quoted token is UNQUOTED rather than dropped, so
# `git push "--force"` and `git "push" -f` still match. A quoted segment
# containing whitespace is prose and is removed.
if ! printf '%s' "$scan" | grep -Eq "$interp" && ! printf '%s' "$scan" | grep -Eq "$subst"; then
  scan=$(printf '%s' "$scan" | perl -pe "s/'([^'[:space:]]*)'/\$1/g; s/\"([^\"[:space:]]*)\"/\$1/g")
  scan=$(printf '%s' "$scan" | perl -pe "s/'[^']*'//g; s/\"[^\"]*\"//g")
fi

# Normalize `git -C <path>` / `--git-dir=` / `--work-tree=` to plain `git`,
# so the verb-based rules below also catch the directory-targeted form
# (e.g. `git -C /repo push --force`).
scan=$(printf '%s' "$scan" | sed -E 's/git +-C +[^ ]+ +/git /g; s/git +--git-dir[= ][^ ]+ +/git /g; s/git +--work-tree[= ][^ ]+ +/git /g')

norm=$scan

deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# --- Secret file access via Bash (Read-tool path deny does NOT cover Bash) ---
if printf '%s' "$norm" | grep -Eq '(\.ssh/|id_rsa|id_ed25519|id_ecdsa|\.aws/|\.netrc|\.pem( |$)|/etc/shadow|\.git-credentials|\.npmrc|\.pypirc)'; then
  deny "Blocked by guard: command references a credential/secret file. Read it yourself if you truly need it."
fi
# .env and friends, but allow .env.example / .sample / .template / .dist
if printf '%s' "$norm" | grep -Eq '\.env[^ ]*' && ! printf '%s' "$norm" | grep -Eq '\.env(\.example|\.sample|\.template|\.dist)'; then
  deny "Blocked by guard: command references a .env file (secrets). Use .env.example, or read it yourself."
fi

# --- Destructive git: force/mirror/delete push ---
if printf '%s' "$norm" | grep -Eq 'git +push\b.*(--force\b|--force-with-lease\b| -f\b|--mirror\b|--delete\b)'; then
  deny "Blocked by guard: force/mirror/delete push can erase remote commits. Run manually if intended."
fi
# Colon-refspec branch deletion: git push origin :branch
if printf '%s' "$norm" | grep -Eq 'git +push +\S+ +:\S'; then
  deny "Blocked by guard: refspec push deletes a remote branch. Run manually if intended."
fi
# Local history rewrites + irreversible remote resource actions.
if printf '%s' "$norm" | grep -Eq \
  'git +reset +.*--hard|git +rebase\b|git +commit\b.*--amend|git +filter-branch\b|git +filter-repo\b|git +reflog +expire\b|git +gc\b.*--prune|git +update-ref +-d\b|git +clean +.*-[a-z]*f|gh +pr +merge\b|gh +repo +delete\b|gh +release +delete\b'; then
  deny "Blocked by guard: command rewrites history or deletes/merges a remote resource. Run manually if intended."
fi
# Forced branch delete: -D, or delete+force in any order/spelling. -D is
# git's own shorthand for both, so it needs no special case here.
branch_delete='\bgit\b[^;&|]*\bbranch\b[^;&|]*( -[dDf]*[dD][dDf]*\b|--delete\b)'
branch_force='\bgit\b[^;&|]*\bbranch\b[^;&|]*( -[dDf]*[fD][dDf]*\b|--force\b)'
if printf '%s' "$norm" | grep -Eq "$branch_delete" && printf '%s' "$norm" | grep -Eq "$branch_force"; then
  deny "Blocked by guard: forced branch delete can lose commits with no other ref. Run manually if intended."
fi

# --- Mass / arbitrary filesystem destruction ---
# find with -delete or -exec rm (since find:* is allowlisted for read use).
if printf '%s' "$norm" | grep -Eq 'find\b.*-delete\b|find\b.*-exec +rm\b'; then
  deny "Blocked by guard: find -delete / -exec rm can mass-delete files. Run manually if intended."
fi
# rm with both recursive and force present, any flag order, short or long.
# Leading space, not (^| ): some greps mis-anchor a non-leading ^ group.
rm_recursive='(^| )rm\b[^;&|]*( -[fiIrRvd]*[rR][fiIrRvd]*\b|--recursive\b)'
rm_force='(^| )rm\b[^;&|]*( -[fiIrRvd]*f[fiIrRvd]*\b|--force\b)'
if printf '%s' "$norm" | grep -Eq "$rm_recursive" && printf '%s' "$norm" | grep -Eq "$rm_force"; then
  deny "Blocked by guard: rm with recursive + force can mass-delete files. Run manually if intended."
fi

# --- Piping into a shell interpreter — hide-the-command / remote-exec bypass ---
# (Inline `bash -c '...'` strings are caught by the regexes above; this covers
#  `curl ... | bash` style wrappers.)
if printf '%s' "$norm" | grep -Eq '\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|fish|dash)\b'; then
  deny "Blocked by guard: piping into a shell can run hidden commands. Run manually if intended."
fi

exit 0
