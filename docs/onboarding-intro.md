# Personal onboarding intros

The managed CLI transport installer also installs `wp-coding-agents-onboarding.php`.
Requires Data Machine's `datamachine_agent_access_granted` and
`datamachine_chat_identity_linked` actions (data-machine#3646). Without those
hooks or operator configuration it does nothing. No release versions changed.

Configure the `wp_coding_agents_onboarding_targets` option (or same-named filter):

```php
[
    'your-agent-slug' => [
        'discord' => [
            'cli_channel' => 'roadie',
            'recipient'   => 'YOUR_ONBOARDING_CHANNEL_ID',
        ],
    ],
]
```

Configure that channel in Roadie's operator-owned `channels.yaml` with the
correct project, audience, response and thread policy. Bind its WordPress
context to the same agent; ensure the person filter resolves thread replies
through the appropriate channel context/default binding. Grant a **user** seat
and link their chat actor, in either order. Audience grants alone do not trigger
personal intros. Any explicit user role qualifies; only admin is unrestricted.
No notifications or shared operator identity are substituted for a missing link.
The Roadie adapter supports Discord personal threads; other bridges opt in via
`wp_coding_agents_onboarding_cli_config` (null means unsupported). That filter
receives existing config, registered CLI config, target, identity link, role,
agent slug, user ID. It must enforce the bridge's personal seat restrictions.
`wp_coding_agents_onboarding_prompt` filters text with slug, user ID and link.

## Async delivery and deduplication

Grant/link requests only schedule a WP-Cron job. A working cron runner is required
(including sites with DISABLE_WP_CRON); no model or child process runs in the
request. The worker rechecks grants and identities against current Data Machine
repositories, then uses the registered CLI's executable, environment and timeout.
One eligible identity/target wins per agent/user. Repeated events are harmless.

Successful intros are recorded in `_wp_coding_agents_intro_<sha256(agent_id)>`
user meta. An atomic, site-local option
`wp_coding_agents_intro_claim_<sha256(user_id:agent_id)>` guards concurrent workers.
Claims are retained on failure, including exceptions/timeouts: delivery can have
succeeded remotely before a local error. This favors no duplicate welcomes over
automatic retries. Failures log a nonfatal diagnostic without private prompts or
child output. Revoke, role changes and unlink do not clear either record.
For a deliberate retry, inspect Roadie for an existing thread first, then delete
the claim option and success meta if present and repeat the link/grant event.
Worker crashes also require this manual recovery. Adding config is not a backfill;
repeat an event for existing people.

## Security findings / PR body

Inspected Extra-Chill/roadie main: `cli/src/cli-commands/send.ts` accepts repeatable
`--permission` rules and `--user` adds thread membership. It does **not** make
the CLI prompt run as that person. Accordingly the proactive turn explicitly
passes all five `TEAM_SEAT_PERMISSIONS` for every non-admin role, including
unknown roles. The managed adapter's rules mirror
`bridges/roadie/roadie-plugins/wordpress-context.mjs`.

For human replies, `cli/src/discord-bot.ts` resolves the authenticated actor via
`resolvePerson` before admission; `session-handler/ingress-input.ts` applies
cached person overrides only to chat actors (never CLI-asserted actors), appending
`person.permissions` to turn permissions. `thread-session-runtime.ts` resolves and
updates session permissions before continuation prompts as well as initial turns.
Thus a CLI-created thread does not permanently inherit the operator's seat when
an admitted person replies. WordPress's person filter supplies their own seat;
MCP registration requires a chat actor and uses their person key. Operators must
keep this plugin and context binding enabled: `--user` alone is not authorization.
Tests cover rule forwarding and the existing WordPress seat adapter; no live
Discord/model end-to-end test was run here.

## Proactive private Connect welcome / PR body

Filed https://github.com/Extra-Chill/roadie/issues/333 with a precise
`roadie send --welcome-person --user ID --channel ID` contract: resolve the target
person, privately deliver pending MCP Connect buttons through the existing
persistent deduplication, deny unknown actors, retain CLI-seat isolation, support
remote send, and advertise the flag in `send --help`.

The adapter probes `send --help` with a five-second bound in the async worker.
Only an advertised `--welcome-person` flag enables the request. Older releases
still receive the personal thread, mention and explicit `/connect` instruction
(one sign-in connects their tools); no unsupported flag or public OAuth link is
sent. Full proactive private buttons await roadie#333. `welcomePersonKey` currently
rejects `via: cli`, so we deliberately do not forge a chat actor to bypass it.

Gate: `tests/onboarding-intro.sh` (PHP harness, installer, real CLI transport smoke,
and WordPress person/seat adapter tests).
