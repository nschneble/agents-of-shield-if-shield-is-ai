# Hooks

Claude Code hooks that ship with the looper definitions. They live here so
they are versioned, reviewable, and testable; `~/.claude/hooks/` holds
symlinks back to these files.

## guard-destructive-git.sh

A `PreToolUse` guard (matcher `Bash`) for autonomous looper runs. It reads
the tool payload on stdin and hard-blocks commands that rewrite history,
take irreversible remote actions, mass-delete files, or read secrets.
Everything else falls through to the normal permission system.

Decisions are `deny` rather than `ask` on purpose: an unattended loop must
not be able to approve these. Run such a command yourself with
`!<command>` when it is genuinely intended.

The guard normalizes whitespace and rewrites `git -C <path>`,
`--git-dir=`, and `--work-tree=` to plain `git`, so directory-targeted and
oddly-spaced forms hit the same rules.

**A plain `git push` is not blocked** — only the force / mirror / delete /
refspec forms are. Over-blocking is its own failure: a guard that gets in
the way of ordinary work gets disabled, and a disabled guard protects
nothing. `guard-destructive-git.test.sh` asserts both directions, with the
green half covering everyday git, read-only `gh`, `find` for search,
`.env.example`-style files, and pipes that do not end in a shell.

## guard-pr-template.sh

A `PreToolUse` guard (matcher `Bash`) that denies a `gh pr create` /
`gh pr edit` whose body uses none of the repo's PR-template sections.

`looper-commit` `## Step 3` already carries this rule and carries it
correctly. It loads only when a body is written inside a `looper-commit`
dispatch, so a body the orchestrator composes by calling `gh` itself
never sees it — and `gh pr create --body` never prefills a template
either. That path shipped this repo's PR #55 in the wrong shape, which is
the whole reason the rule needed a mechanical arm rather than another
sentence.

**The bar is one marker, not a full fill.** A body containing any single
section the template declares passes. That catches "wrote my own
headings," which is the failure; judging whether a fill is COMPLETE is
the reviewer's job, and a hook attempting it would be wrong more often
than the author. It reads a `--body-file`'s contents, expanding plain
`$VAR` / `${VAR}` from its own environment because the command has not
run yet — never `$( )` or backticks, which would execute what it is
supposed to be inspecting.

It fails OPEN wherever it cannot see clearly: no template, a template
with no extractable sections, a `PULL_REQUEST_TEMPLATE/` directory (which
GitHub never auto-applies), a body on stdin, an unreadable path, or
`--repo` pointing somewhere that is not this tree. Same reasoning as the
git guard's plain-`git push` carve-out: a guard that blocks on its own
blind spots is one people route around.

## record-execution-receipt.sh

`PostToolUse`, matcher `Bash`. Appends one receipt per shell execution to
`local/loops/<branch>/receipts.jsonl` — the command, whether it was
interrupted, digests of stdout and stderr, and a timestamp.

It exists because `verified_by` on a gate line is free text the audited
agent types, so a rule reading it asks that agent to grade itself. A
receipt is written by the runtime and no agent authors it.

There is no exit code in it, and that is not an omission: the PostToolUse
payload's `tool_response` carries only `interrupted`, `isImage`,
`noOutputExpected`, `stderr`, `stdout`. The event fires on tool SUCCESS —
failures route to `PostToolUseFailure`, which nothing here subscribes to
— so a receipt's existence is the success signal. An earlier version read
`.tool_response.exit_code`, recorded null on all 159 real receipts, and
made `scripts/loop-receipts.sh`'s clean arm unreachable.

Unlike the two guards it never blocks and never fails a call: every arm
exits 0, and nothing is written for a non-Bash tool or a cwd outside a
git repo. `local/` is gitignored, so receipts are scratch.

Read by `scripts/loop-receipts.sh`; tested by
`scripts/loop-receipts.test.sh`, which covers both the writer and the
check (this hook has no sibling `*.test.sh` of its own).

## Deployment

Claude Code reads hooks from `~/.claude/`, so each hook is symlinked out
of this directory, the same arrangement `~/.claude/scripts` uses:

```
ln -sfn "$PWD/hooks/guard-destructive-git.sh" ~/.claude/hooks/guard-destructive-git.sh
ln -sfn "$PWD/hooks/guard-pr-template.sh" ~/.claude/hooks/guard-pr-template.sh
ln -sfn "$PWD/hooks/record-execution-receipt.sh" ~/.claude/hooks/record-execution-receipt.sh
```

The wiring itself lives in `~/.claude/settings.json`, which is not
versioned here. Both guards sit under the one `PreToolUse` `Bash` matcher
and run in order; the receipt writer sits under `PostToolUse`:

```json
{ "hooks": {
  "PreToolUse": [ { "matcher": "Bash", "hooks": [
    { "type": "command", "command": "~/.claude/hooks/guard-destructive-git.sh" },
    { "type": "command", "command": "~/.claude/hooks/guard-pr-template.sh" }
  ] } ],
  "PostToolUse": [ { "matcher": "Bash", "hooks": [
    { "type": "command", "command": "~/.claude/hooks/record-execution-receipt.sh" }
  ] } ]
} }
```

A newly added hook does not take effect in a session that was already
running when it was wired: the settings watcher only picks up files it
was watching at startup. Open `/hooks` once, or restart.

Editing the file in this repo changes the live hook immediately through
the symlink. There is no deploy step, and equally no staging: a broken
edit here is a broken guard now, which is why the test is wired into CI.
