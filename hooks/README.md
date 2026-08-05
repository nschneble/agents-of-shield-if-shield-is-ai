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

## Deployment

Claude Code reads hooks from `~/.claude/`, so each hook is symlinked out
of this directory, the same arrangement `~/.claude/scripts` uses:

```
ln -sfn "$PWD/hooks/guard-destructive-git.sh" ~/.claude/hooks/guard-destructive-git.sh
```

The wiring itself lives in `~/.claude/settings.json`, which is not
versioned here:

```json
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
  { "type": "command", "command": "~/.claude/hooks/guard-destructive-git.sh" }
] } ] } }
```

Editing the file in this repo changes the live hook immediately through
the symlink. There is no deploy step, and equally no staging: a broken
edit here is a broken guard now, which is why the test is wired into CI.
