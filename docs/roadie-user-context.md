# Current-speaker WordPress context

Roadie's native `person` and `context_sections` hooks resolve chat speakers
without assigning the conversation owner's identity to every participant.
WordPress supplies registered memory; Roadie carries the authenticated actor.

The installer copies `wordpress-context.mjs` into the managed Roadie plugin
directory. It is a thin adapter over Data Machine's
`datamachine/resolve-chat-person` ability: WordPress decides who the speaker
is, whether they may use the agent, which seat they hold and which memory they
get. The plugin activates only when the operator provides
`roadie-config/wordpress-context.json` (version 1), which binds Roadie
contexts to a site and agent and nothing else:

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
  }
}
```

`WP_CODING_AGENTS_ROADIE_CONTEXT_CONFIG` can select its path. Multiple
channels can share the same context. Roadie's context/project binding selects
a named context; `channelContexts` can explicitly bind identity lookup
channels when several contexts are configured.

## Chat identity links

A chat actor is linked to a WordPress user in Data Machine, on the user, per
platform. Links are not scoped by server, guild or workspace, so moving the
bot to another server needs no change:

```sh
wp datamachine chat-identity link discord <discord-user-id> --user=<user>
wp datamachine chat-identity link slack <slack-user-id> --user=<user>
wp datamachine chat-identity list
wp datamachine chat-identity unlink discord --user=<user>
```

Display names never resolve identity. Unlinked actors are denied when this
plugin is configured. The linked user must be the agent owner, a WordPress
administrator, or hold a viewer-or-higher Data Machine agent grant; the
canonical `datamachine_can_access_agent` filter also applies.

The old `people` block (`<platform>:<space>:<actor>` → `userId`,
`capabilities`) is no longer read. A leftover block grants nothing and logs a
warning; link each entry with the command above, then delete the block.

## Calling the ability

Each lookup runs `wp --path=<sitePath> eval '<one Abilities API call>'`
through the context's `transport`, so remote control transports work as
before and no PHP or memory file is copied into the runtime. The evaluated
code only calls `wp_get_ability( 'datamachine/resolve-chat-person' )->execute()`
and prints the JSON result; it touches no Data Machine class. WP-CLI runs it
as the host operator. PHP diagnostics that wp-cli prints ahead of the JSON
are tolerated; any other output fails the lookup.

| Roadie hook | Ability input | Used from the result |
|-------------|---------------|----------------------|
| `person` | `platform`, `actor_id`, `event: person` | `allowed`, `user_id` (person id `wordpress:<sitePath>:<user_id>`), `role` |
| `context_sections`, `turn` | `platform`, `actor_id`, `event: turn` | personal sections, only when `user_id` matches Roadie's person id |
| `context_sections`, other events | empty `actor_id` | agent-layer sections returned with `allowed: false`, `reason: no_actor` |

Shared context needs Data Machine with actorless resolution
(data-machine#3615). On older versions the `session_start` lookup fails with
a message naming that change; Roadie logs it and continues without shared
memory.

## Lookup failures and slow sites

Each lookup runs WP-CLI through the context's `transport` with a 12 second
bound. A local site whose WP-CLI boots slower (a desktop WordPress app, a cold
container) can raise it per context with `"lookupTimeoutMs": 30000` (1000 to
120000). When a lookup fails, Roadie answers "Couldn't verify your account"
and logs the cause: command not found (transport or service PATH), timed out
(raise `lookupTimeoutMs`), or the exit status with the tail of stderr, such as
a PHP fatal error.

## Per-person MCP servers

A context can name MCP servers that every allowed seat gets as its own
(Roadie person-MCP, roadie#152):

```json
"site-agent": {
  "sitePath": "/srv/site",
  "agentSlug": "site-agent",
  "mcpServers": [
    {"name": "site", "url": "https://auth.example.com/wp-json/extrachill-mcp/v1/mcp"}
  ]
}
```

`credential` defaults to `name`. Names must match `^[a-z0-9][a-z0-9_-]{0,39}$`
and URLs must be https (http only on loopback). Invalid or duplicate entries
are dropped. Roadie registers each server with the speaker's own OAuth token
and only for that speaker's turns. The person connects once in chat with
`/connect` (OAuth device grant, roadie#271), so WordPress abilities run as
that WordPress user, within their own capabilities. Until they connect, the
server is simply absent.

## Seat tiers

The ability returns the speaker's Data Machine agent access role: the agent
owner and WordPress administrators are `admin`, otherwise the grant's role
(`operator` or `viewer`). A user admitted only through
`datamachine_can_access_agent` is a `viewer`. The role decides the seat:

| Role | Roadie capabilities | Session permission rules |
|------|---------------------|--------------------------|
| `admin` | `sessions`, `shell`, `admin` | none (full toolset) |
| `operator`, `viewer`, missing/unknown | `sessions` only | `bash:deny`, `edit:deny`, `external_directory:deny`, `read:*wp-config.php:deny`, `grep:*wp-config.php:deny` |

Roadie's `shell` capability only gates user-typed raw shell (`!cmd`,
`/run-shell-command`). The agent's own tools follow the host runtime config,
which on a WordPress host includes the operator's credentials (for example the
host `gh` login). Without these rules every admitted seat would hold them. A
team seat's agent can still read the site tree inside the session directory
and use Roadie's own tools; it acts on WordPress through abilities (per-person
MCP, roadie#152) rather than through shell. Rules are applied per turn, so in a
shared thread an admin's turn runs unrestricted and a team member's turn runs
restricted.

Shared/agent memory is supplied on `session_start`, without a speaker. User
and agent-user memory is supplied on `turn`, for the speaker Roadie
authenticated: the actor is resolved again and must still link to the same
user, so an unlinked actor stops receiving personal memory on the next turn.
Sections that Data Machine marks with a `convention_path` (for example
`AGENTS.md`) are skipped when the runtime already loads that file from the
session directory or one of its ancestors (#733).

The provider needs Roadie's first-turn/reconstructed-turn speaker-context fix
(roadie #102). Shared context is pinned without a speaker. First turns,
speaker changes, and reconstruction resolve the current user separately.

With this configuration present, the provider owns all Data Machine memory:
setup/upgrade removes every managed memory path (shared, agent, user and
principal) from the static OpenCode instructions, so Roadie's Pi sessions get
it from one place and never twice. Operator-owned instructions remain intact. Existing sessions have
historical prompts and user context; create a fresh conversation to establish
the new shared prompt contract.

Layer selection, size caps and memory reads belong to the ability.

This identity link supplies **context and chat admission**, not impersonation for
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

The plugin test runs the adapter against a fake WordPress that plays the
ability. It verifies seat tiers (admin unrestricted; operator, viewer and
missing roles restricted; denied and unlinked rejected), platform-scoped
links across servers, two concurrent users, Discord/Slack actors, mismatched
and missing identities, unlinking between turns, actorless shared context,
the pre-#3615 failure, convention-file skipping, and that the adapter never
asserts a WordPress user. It also runs the generated PHP against a stub
ability. Before activation, run the plugin read-only against the target's
registered agent with a linked actor and a `session_start`, checking section
ids without printing private content.
