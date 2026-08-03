#!/bin/bash
# guidance/wordpress-source.engineering.sh — installed WordPress source, engineering posture.
#
# Same purpose as the managed variant: CAPABILITY. The agent should be an expert
# on its own runtime by reading the WordPress actually installed here rather
# than relying on training data. The read-only boundary is a qualifier, not the
# point — see the header of wordpress-source.managed.sh and #322.
#
# What differs from managed is only where changes land: engineering routes them
# through a Data Machine Code workspace so they are tracked in git and reviewed.

guidance_id() { printf 'wordpress-source'; }
guidance_priority() { printf '1'; }
guidance_label() { printf 'WordPress Source'; }
guidance_description() { printf 'Points the agent at the installed WordPress source as read-only reference.'; }
guidance_freshness() { printf 'static'; }
guidance_conditions() { printf 'Registered by wp-coding-agents on engineering-posture installations.'; }

guidance_render() {
  cat <<'MD'
## WordPress Source (Direct Reference, Read-Only)

The WordPress running this site is on disk underneath you. Read it to verify core APIs, hooks, conventions, and runtime behavior instead of relying on assumptions:

- `wp-includes/` — core internals: the hook system, query, HTTP, database, and template APIs.
- `wp-admin/` — the other half of core: admin screens, list tables, media and upgrade routines.
- `wp-content/plugins/` and `wp-content/themes/` — every extension installed here.

Grep and read these freely. They are the ground truth for how this site actually behaves.

These paths are **read-only reference**. Make code changes in the configured managed workspace, not in the installed source tree.
MD
}
