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

## No OpenCode plugins (#718)

A wp-coding-agents Roadie install ships **no OpenCode plugins**. The four the
bridge used to install into `roadie-config/plugins` and wire into
`opencode.json` are retired in favor of Roadie-native primitives; upgrades
remove the files and drop their `opencode.json` entries (additively — user
plugins survive):

| Retired plugin | Roadie-native replacement |
| --- | --- |
| `dm-agent-sync.ts` | Roadie's `wordpress-context` plugin / `--context-provider` supplies Data Machine memory per session and speaker |
| `roadie-command-guard.ts` | Project-channel creation is gone from Roadie (roadie#187): channels come only from `ROADIE_CHANNELS_CONFIG` |
| `session-attribution.ts` | Roadie's `--shell-env` / `ROADIE_SHELL_ENV` templates (roadie#186), rendered into the managed service env |
| `claude-code-auth.ts` | Nothing to replace: it registered nothing under Roadie — Roadie's credential pools serve Anthropic. Kept for direct non-Roadie OpenCode installs. |

### Memory

`dm-agent-sync.ts` only refreshed memory before a session's first message.
Memory delivery itself is unchanged: setup and upgrade still sync Data
Machine's injectable files into `opencode.json` `instructions`, and with
`wordpress-context.json` configured, per-user memory comes from Roadie's
`wordpress-context` plugin instead (`--speaker-context`). Freshness now follows
Data Machine's own composition (or a manual `wp datamachine memory compose`)
rather than a compose on every session start.

### Session attribution

Roadie's configurable agent-shell environment (roadie#186) replaces
`session-attribution.ts`. The managed service env carries

```
ROADIE_SHELL_ENV={"HOMEBOY_CALLER_CONTEXT":"roadie:session:{session_id}","HOMEBOY_SESSION_SEND_COMMAND":"<roadie bin> send","HOMEBOY_SESSION_THREAD_ID":"{thread_id}"}
```

in both the systemd unit and the launchd plist. Roadie substitutes
`{session_id}` and `{thread_id}` wherever it builds an agent shell
environment — falling back to the session's thread binding exactly like the
plugin's `roadie session discord-url` lookup — and leaves a variable unset
when its fields have no value for the turn, which preserves the plugin's fork
rule (a forked shell never inherits the parent's caller context). The bot
token is still never exported.

Differences from the plugin: `HOMEBOY_SESSION_SEND_COMMAND` uses the resolved
roadie binary (unset if the path contains whitespace, so delivery falls back
to REST), and a configured template wins over an inherited value — an
operator-set `HOMEBOY_SESSION_SEND_COMMAND` or `HOMEBOY_SESSION_SEND_URL` no
longer takes precedence; drop the entry from the managed mapping to reclaim
that.

## Verification

```bash
bash tests/roadie-managed-env.sh
bash tests/opencode-local-plugin-path.sh
bash tests/repair-opencode-json.sh
```

`tests/roadie-managed-env.sh` asserts the rendered systemd unit and launchd
plist both carry `ROADIE_SHELL_ENV` with the `HOMEBOY_SESSION_*` mapping.
`tests/opencode-local-plugin-path.sh` asserts a Roadie install generates no
`plugin` array and no plugin files, while a direct OpenCode install keeps
`claude-code-auth.ts`.
