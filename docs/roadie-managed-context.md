# Managed Roadie context and ownership

Roadie supplies the Discord bridge. Composed agent guidance owns coding runtime,
workspace, orchestration, and evidence policy.

## Prompt contract

Roadie builds its system prompt from named sections and reads a prompt config
from `ROADIE_PROMPT_CONFIG`. The managed `bridges/roadie/prompt-config.yaml`
disables every built-in section and appends the compact bridge contract, so
Roadie's generic worktree, tunnel, and session-fanout guidance never reaches
the model. Nothing is filtered after the fact: the sections are not generated.

Kimaki installs needed an OpenCode plugin (`dm-context-filter`) that rewrote the
assembled request and refused dispatch when a later hook reinjected generic
instructions. Roadie's prompt config replaces it; upgrades drop the plugin
entry from `opencode.json`.

## Independent command ownership guard

`roadie-command-guard.ts` (`tool.execute.before`) rejects ordinary Bash launches
of Roadie coding sessions and project creation: `roadie send` without
`--notify-only`, any send targeting `--cwd`, `--thread`, `--session`, or
`--worktree`, and `roadie project add|create`. It covers direct and absolute
executable paths, common shell/environment/package-manager wrappers, compound
commands, and command substitution. Shell help, notification-only sends,
uploads, and archive commands remain available. Quoted command examples printed
as data remain intact.

This is an operational ownership guard, **not an arbitrary-code sandbox**.
Dynamic programs can invoke subprocesses outside these recognized CLI launch
forms. The managed runtime's own workspace admission and permission boundaries
remain necessary. Operators change policy through managed configuration; an
instruction in the conversation is not an override.

## Session attribution

`session-attribution.ts` maps the Roadie thread of an agent shell
(`ROADIE_THREAD_ID`, exported by Roadie, or `roadie session discord-url`) onto
Homeboy's bridge-neutral `HOMEBOY_SESSION_*` contract. The bot token is never
exported to agent shells.

## Verification

```bash
bash tests/roadie-command-guard.sh
bun tests/session-attribution.mjs
```

The guard suite runs unit cases, then, when OpenCode is installed, a live probe:
the installed OpenCode executable runs in an isolated temporary project with a
loopback-only model fixture that returns a forbidden `roadie send --worktree`
tool call. The refusal must reach the model as a tool result before a harmless
sentinel executable can run. It uses no model account and does not touch the
running bot.
