# Current-speaker WordPress context

Roadie's native `person` and `context_sections` hooks resolve chat speakers
without assigning the conversation owner's identity to every participant.
WordPress supplies registered memory; Roadie carries the authenticated actor.

The installer copies `wordpress-context.mjs` and its PHP resolver into the
managed Roadie plugin directory. They activate only when the operator provides
`roadie-config/wordpress-context.json` (version 1):

```json
{
  "version": 1,
  "defaultContext": "site-agent",
  "contexts": {
    "site-agent": {
      "sitePath": "/srv/site",
      "agentSlug": "site-agent",
      "transport": ["wp"]
    }
  },
  "people": {
    "discord:SERVER_ID:USER_ID": {"userId": 12, "capabilities": ["sessions"]},
    "slack:WORKSPACE_ID:USER_ID": {"userId": 23, "capabilities": ["sessions"]}
  }
}
```

Mappings are explicit platform + space + account identifiers. Display names
never resolve identity. The mapping file is operator-owned configuration, not
generated memory. `WP_CODING_AGENTS_ROADIE_CONTEXT_CONFIG` can select its path.
Multiple channels can share the same context. Roadie's context/project binding
selects a named context; `channelContexts` can explicitly bind identity lookup
channels when several contexts are configured.

The selected WordPress user must exist and be the persisted agent owner, a
WordPress administrator, or have an existing viewer-or-higher agent grant.
The canonical `datamachine_can_access_agent` filter also applies.
Capabilities are explicitly declared in the mapping; defaults grant sessions
only. Unmapped actors are denied when this identity plugin is configured.

Shared/agent memory is supplied on `session_start`. User and agent-user memory
is supplied on `turn`, through Data Machine's registered memory store. The
provider verifies the actor's space-scoped mapping again before reading user
memory. It supports local WP-CLI and explicit external control argv without
copying private user memory into the hosted runtime.

The provider needs Roadie's first-turn/reconstructed-turn speaker-context fix
(roadie #102), including `spaceId` on context requests. Activate it only after
that version is installed. Shared context is pinned without a speaker. First
turns, speaker changes, and reconstruction resolve the current user separately.

With this configuration present, setup/upgrade removes managed user/principal
memory paths from the static OpenCode instructions. Operator-owned instructions
remain intact. Existing sessions have historical prompts and user context;
create a fresh conversation to establish the new shared prompt contract.

This mapping supplies **context and chat admission**, not impersonation for
WordPress abilities. It does not set the acting WP user, credentials, approval
owner, or asynchronous run owner. Those require their own explicit execution
principal contract. CLI-asserted actors cannot obtain personal context.

A shared conversation still contains the prior participants' messages and
context. Use separate sessions for private conversations.

Verification:

```sh
bash tests/roadie-wordpress-context.sh
bash tests/bridge-render.sh
bash tests/repair-opencode-json.sh
```

The plugin test verifies two concurrent users, Discord/Slack mapping, wrong
spaces, missing and mismatched identities, mapping removal, and absence of
acting-user promotion. The PHP boundary fixture verifies shared/user/principal
layer selection. Before activation, run the provider against the target's
registered agent and an explicit mapped user, checking section IDs without
printing private content. Roadie's real-backend mixed-speaker scenario verifies
first/change/return/reconstructed turns separately.
