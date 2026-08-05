#!/bin/bash
# guidance/abilities.sh — WordPress Abilities discovery guidance.
#
# Mode-neutral: abilities are the tool surface in both workspace and
# owned-mode installs, and the routing advice does not change with the agent's
# relationship to installed source.

guidance_id() { printf 'abilities'; }
guidance_priority() { printf '2'; }
guidance_label() { printf 'Abilities'; }
guidance_description() { printf 'Generic WordPress Abilities discovery guidance.'; }
guidance_freshness() { printf 'static'; }
guidance_conditions() { printf 'Registered by wp-coding-agents on managed WordPress coding-agent installations.'; }

guidance_render() {
  cat <<'MD'
## Abilities

WordPress Abilities are the universal tool surface. Plugins expose abilities through the active runtime, REST API, MCP, and chat.

**Default routing**
- Use abilities exposed by the active runtime when they match the task.
- Inspect the active runtime tool listings and plugin-specific `--help` before assuming a capability or argument is available.
MD
}
