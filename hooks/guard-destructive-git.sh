#!/usr/bin/env bash
# PreToolUse guard for autonomous looper runs (matcher: Bash).
# Hard-blocks commands that can rewrite history, do irreversible remote
# actions, mass-delete files, or read secrets — regardless of flag order.
# Everything else passes through to the normal permission system.
#
# Decisions are "deny" (not "ask"): an unattended loop must not be able to
# approve these. Run such a command yourself with `!<command>` if intended.

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

# Collapse whitespace so flags split across spacing still match.
norm=$(printf '%s' "$cmd" | tr -s '[:space:]' ' ')

# Normalize `git -C <path>` / `--git-dir=` / `--work-tree=` to plain `git`,
# so the verb-based rules below also catch the directory-targeted form
# (e.g. `git -C /repo push --force`).
norm=$(printf '%s' "$norm" | sed -E 's/git +-C +[^ ]+ +/git /g; s/git +--git-dir[= ][^ ]+ +/git /g; s/git +--work-tree[= ][^ ]+ +/git /g')

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
  'git +reset +.*--hard|git +rebase\b|git +commit\b.*--amend|git +branch +-D\b|git +filter-branch\b|git +filter-repo\b|git +reflog +expire\b|git +gc\b.*--prune|git +update-ref +-d\b|git +clean +.*-[a-z]*f|gh +pr +merge\b|gh +repo +delete\b|gh +release +delete\b'; then
  deny "Blocked by guard: command rewrites history or deletes/merges a remote resource. Run manually if intended."
fi

# --- Mass / arbitrary filesystem destruction ---
# find with -delete or -exec rm (since find:* is allowlisted for read use).
if printf '%s' "$norm" | grep -Eq 'find\b.*-delete\b|find\b.*-exec +rm\b'; then
  deny "Blocked by guard: find -delete / -exec rm can mass-delete files. Run manually if intended."
fi

# --- Piping into a shell interpreter — hide-the-command / remote-exec bypass ---
# (Inline `bash -c '...'` strings are caught by the regexes above; this covers
#  `curl ... | bash` style wrappers.)
if printf '%s' "$norm" | grep -Eq '\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|fish|dash)\b'; then
  deny "Blocked by guard: piping into a shell can run hidden commands. Run manually if intended."
fi

exit 0
