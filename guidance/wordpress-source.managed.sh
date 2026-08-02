#!/bin/bash
# guidance/wordpress-source.managed.sh — installed WordPress source, managed posture.
#
# Managed agentic hosting: the agent edits the live theme and plugins in place at
# the owner's request. There is no workspace, no git, and no GitHub in its world.
# Matches the permissions lib/source-policy.sh hands the runtimes for this
# posture: themes and plugins editable, wp-includes still read-only.
#
# This prose deliberately carries facts the engineering variant has no reason to
# state. An agent editing production needs to know that its changes are live on
# save, that they are unbacked until captured, and which paths a capture will
# silently skip. Omitting those is how an agent loses a day of work in a path
# nobody told it was excluded.

guidance_id() { printf 'wordpress-source'; }
guidance_priority() { printf '1'; }
guidance_label() { printf 'WordPress Source'; }
guidance_description() { printf 'Live-edit boundaries and production contract for installed WordPress source.'; }
guidance_freshness() { printf 'static'; }
guidance_conditions() { printf 'Registered by wp-coding-agents on managed-posture installations, where the agent edits live site source directly.'; }

guidance_render() {
  cat <<'MD'
## WordPress Source (Live, Editable)

This site's theme and plugins are yours to edit directly. The installed tree is the working tree — there is no separate checkout, no workspace, and no pull request step.

- `wp-content/themes/` — **editable**, this site's own theme source
- `wp-content/plugins/` — **editable**, this site's own plugin source
- `wp-includes/` — WordPress core, **read-only**. Never edit core; change your theme or plugin instead.

Read the installed source directly to verify APIs, hooks, and runtime behavior rather than relying on assumptions.

### Working on production

- **Your edits are live the moment you save them.** There is no staging environment, no review gate, and no deploy step between you and the public site. A syntax error is a down site.
- **Verify before you leave a change in place.** Load the affected page or run the relevant WP-CLI command. You are the only check that runs before visitors see it.
- **Work is unbacked until it is captured.** Changes are harvested into version control out-of-band on a schedule the operator owns, and each capture becomes a restore point. Between your edit and the next capture, the live file is the only copy.
- **Rollback is an operator action.** You cannot revert to a previous restore point yourself. If something breaks and you cannot fix it forward, say so plainly and immediately rather than continuing to edit.

### Changes that will not be captured

Dependency trees, lockfiles, and build output are installed or generated rather than authored, so a capture skips them. Editing them on the live site produces a change that is **never recorded and is destroyed by the next deploy**:

- `vendor/` and `node_modules/` — installed dependency trees
- `composer.lock`, `package-lock.json`, `package.json` — dependency manifests
- generated build output

If a task genuinely requires changing one of these, stop and tell the operator. It needs to happen in the source repository, not here.
MD
}
