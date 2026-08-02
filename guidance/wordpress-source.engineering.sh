#!/bin/bash
# guidance/wordpress-source.engineering.sh — installed WordPress source, engineering posture.
#
# The agent treats the installed tree as reference material and makes every code
# change in a Data Machine Code workspace, tracked in git and reviewed through
# GitHub. Matches the deny rules lib/source-policy.sh hands the runtimes for this
# posture: all three roots read-only, workspace granted.

guidance_id() { printf 'wordpress-source'; }
guidance_priority() { printf '1'; }
guidance_label() { printf 'WordPress Source'; }
guidance_description() { printf 'Direct-reference and read-only boundaries for installed WordPress source.'; }
guidance_freshness() { printf 'static'; }
guidance_conditions() { printf 'Registered by wp-coding-agents on engineering-posture installations.'; }

guidance_render() {
  cat <<'MD'
## WordPress Source (Direct Reference, Read-Only)

Use the installed WordPress source to verify core APIs, hooks, conventions, and runtime behavior instead of relying on assumptions. Search and read these directories directly when working on WordPress:

- `wp-content/plugins/` — plugin source (read-only)
- `wp-content/themes/` — theme source (read-only)
- `wp-includes/` — WordPress core (read-only)

These paths are **read-only references**. Make code changes in the configured managed workspace, not in the installed source tree.
MD
}
