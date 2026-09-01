#!/usr/bin/env bash
# PreToolUse guard (Bash) for autonomous looper runs: denies history
# rewrites, irreversible remote actions, mass deletion, secret reads,
# regardless of flag order. Deny, not ask: an unattended loop can't
# approve these. See ## Scan string for what is stripped before matching.

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

# --- Scan string: with interpreter or $()/backtick, nothing stripped ---
interp='(^|[;&|(]| )(sudo +)?(bash|sh|zsh|dash|fish|ksh|eval|exec|source|xargs|ssh|python3?|node|perl|ruby|php|awk)\b'
subst='\$\(|`'

scan=$cmd

# heredoc bodies are stdin data, except when fed straight to an interpreter
if ! printf '%s' "$cmd" | grep -Eq '(bash|sh|zsh|dash|fish|ksh|python3?|node|perl|ruby|php) *<<'; then
  scan=$(printf '%s' "$scan" | perl -0777 -pe 's/<<-?[ \t]*(["'\'']?)(\w+)\1.*?^[ \t]*\2[ \t]*$//gms')
fi

# Collapse whitespace so flags split across spacing still match.
scan=$(printf '%s' "$scan" | tr -s '[:space:]' ' ')

# quoted args, no interpreter/subst: a single-word quote is unquoted
if ! printf '%s' "$scan" | grep -Eq "$interp" && ! printf '%s' "$scan" | grep -Eq "$subst"; then
  scan=$(printf '%s' "$scan" | perl -pe "s/'([^'[:space:]]*)'/\$1/g; s/\"([^\"[:space:]]*)\"/\$1/g")
  scan=$(printf '%s' "$scan" | perl -pe "s/'[^']*'//g; s/\"[^\"]*\"//g")
fi

# normalize `git -C <path>` etc to plain `git` so verb rules below catch it
scan=$(printf '%s' "$scan" | sed -E 's/git +-C +[^ ]+ +/git /g; s/git +--git-dir[= ][^ ]+ +/git /g; s/git +--work-tree[= ][^ ]+ +/git /g')

norm=$scan

deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# --- Secret file access via Bash (Read-tool deny does not cover Bash) ---
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
# forced branch delete: -D is delete+force, so no special case needed
branch_delete='\bgit\b[^;&|]*\bbranch\b[^;&|]*( -[dDf]*[dD][dDf]*\b|--delete\b)'
branch_force='\bgit\b[^;&|]*\bbranch\b[^;&|]*( -[dDf]*[fD][dDf]*\b|--force\b)'
if printf '%s' "$norm" | grep -Eq "$branch_delete" && printf '%s' "$norm" | grep -Eq "$branch_force"; then
  deny "Blocked by guard: forced branch delete can lose commits with no other ref. Run manually if intended."
fi

# --- gh api: the same actions above, reached via raw REST/GraphQL ---
# each check is its own grep, chained with &&: some mis-chain \bWORD\b
api_scope='\bgh\b[^;&|]*\bapi\b'
if printf '%s' "$norm" | grep -Eq "$api_scope"; then
  method_put='(-X|--method) *[Pp][Uu][Tt]\b'
  method_delete='(-X|--method) *[Dd][Ee][Ll][Ee][Tt][Ee]\b'
  method_patch='(-X|--method) *[Pp][Aa][Tt][Cc][Hh]\b'
  path_pr_merge='pulls/[0-9]+/merge\b'
  # repos/OWNER/REPO with nothing after it: gh repo delete's real endpoint.
  path_delete_targets='(repos/[^/ ]+/[^/ ]+( |$)|releases/([0-9]+|latest|tags/[^ ]+)\b|git/refs/heads/[^ ]+\b)'
  # POST to git/refs/ creates a branch (safe); PATCH force-moves one.
  path_force_ref='git/refs/[^ ]+\b'
  if printf '%s' "$norm" | grep -Eq "$method_put" \
     && printf '%s' "$norm" | grep -Eq "$path_pr_merge"; then
    deny "Blocked by guard: gh api PR merge. Run manually if intended."
  fi
  if printf '%s' "$norm" | grep -Eq "$method_delete" \
     && printf '%s' "$norm" | grep -Eq "$path_delete_targets"; then
    deny "Blocked by guard: gh api delete (repo/release/branch). Run manually if intended."
  fi
  if printf '%s' "$norm" | grep -Eq "$method_patch" \
     && printf '%s' "$norm" | grep -Eq "$path_force_ref"; then
    deny "Blocked by guard: gh api force ref update. Run manually if intended."
  fi
  if printf '%s' "$norm" | grep -Eq '\bgraphql\b'; then
    deny "Blocked by guard: gh api graphql can mutate via a query string this guard can't parse. Run manually if intended."
  fi
fi

# --- Mass / arbitrary filesystem destruction ---
# find with -delete or -exec rm (since find:* is allowlisted for read use).
if printf '%s' "$norm" | grep -Eq 'find\b.*-delete\b|find\b.*-exec +rm\b'; then
  deny "Blocked by guard: find -delete / -exec rm can mass-delete files. Run manually if intended."
fi
# rm recursive+force, any order; leading space avoids mis-anchored ^ group
rm_recursive='(^| )rm\b[^;&|]*( -[fiIrRvd]*[rR][fiIrRvd]*\b|--recursive\b)'
rm_force='(^| )rm\b[^;&|]*( -[fiIrRvd]*f[fiIrRvd]*\b|--force\b)'
if printf '%s' "$norm" | grep -Eq "$rm_recursive" && printf '%s' "$norm" | grep -Eq "$rm_force"; then
  deny "Blocked by guard: rm with recursive + force can mass-delete files. Run manually if intended."
fi

# --- piping into a shell: `curl ... | bash` style wrappers ---
if printf '%s' "$norm" | grep -Eq '\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|fish|dash)\b'; then
  deny "Blocked by guard: piping into a shell can run hidden commands. Run manually if intended."
fi

exit 0
