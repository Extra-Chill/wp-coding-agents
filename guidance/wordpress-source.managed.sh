#!/bin/bash
# guidance/wordpress-source.managed.sh — installed WordPress source, managed posture.
#
# WHAT THIS SECTION IS FOR
#
# Capability, not restriction. It exists so the agent stops guessing at
# WordPress and reads the source actually running underneath it — that is what
# lets a small model be competent about WordPress with no skills and no
# fine-tuning. Reference is the point; the ownership boundary is a qualifier.
#
# Restriction is the permission layer's job and is already enforced there
# (lib/source-policy.sh). Prose enforces nothing, so restating the deny list
# here buys no safety while crowding out the one thing prose is uniquely good
# at. The boundary appears only so the agent is not MISINFORMED about what it
# may change — a far smaller job than policing it. See #322.
#
# TWO RULES WHEN EDITING THIS FILE
#
# 1. Enumerate, never generalise. The editable set comes from
#    source_policy_owned_sources and is printed path by path. An earlier
#    version said "this site's theme and plugins" while the policy opened
#    `wp-content/plugins/**` wholesale — #318.
#
# 2. Assert only what wp-coding-agents actually knows. This text ships to EVERY
#    managed install, so it must not describe one site's stack as if it were
#    universal. An earlier version named "commerce and payment code" and "the
#    site's ability to take money" (there may be no store), and listed one
#    operator's harvest excludes verbatim — a config this tool cannot read.
#    Describe the CATEGORY and the REASON; leave the specifics to the
#    operator. #320.

guidance_id() { printf 'wordpress-source'; }
guidance_priority() { printf '1'; }
guidance_label() { printf 'WordPress Source'; }
guidance_description() { printf 'Points the agent at the installed WordPress source and names the trees this site owns.'; }
guidance_freshness() { printf 'conditional'; }
guidance_conditions() { printf 'Registered on managed-posture installations; the owned-source list is generated from the declared managed sources.'; }

guidance_render() {
  local owned writable
  owned="$(source_policy_owned_sources)"
  writable="$(source_policy_writable_paths)"

  printf '%s\n' '## WordPress Source'
  printf '\n'
  printf '%s\n' 'The WordPress running this site is on disk underneath you. Read it to verify core APIs, hooks, conventions, and runtime behavior instead of relying on assumptions:'
  printf '\n'
  printf '%s\n' '- `wp-includes/` — core internals: the hook system, query, HTTP, database, and template APIs.'
  printf '%s\n' '- `wp-admin/` — the other half of core: admin screens, list tables, media and upgrade routines.'
  printf '%s\n' '- `wp-content/plugins/` and `wp-content/themes/` — every extension installed here, including the ones this site depends on.'
  printf '\n'
  printf '%s\n' 'Grep and read these freely. They are the ground truth for how this site actually behaves.'
  printf '\n'

  if [ -z "$owned" ] && [ -z "$writable" ]; then
    printf '%s\n' 'Nothing on this install is declared as editable, so treat all of it as reference. If a task requires changing code, say that no editable source is configured rather than picking somewhere to edit.'
    return 0
  fi

  printf '%s\n' '### What is yours to change'
  printf '\n'

  if [ -n "$owned" ]; then
    printf '%s\n' 'This site owns these, and they are the complete list. You edit them in place — there is no checkout, no workspace, and no pull request step:'
    printf '\n'
    printf '%s\n' "$owned" | while IFS= read -r path; do
      [ -n "$path" ] || continue
      printf -- '- `%s/`\n' "$path"
    done
    printf '\n'
  fi

  if [ -n "$writable" ]; then
    printf '%s\n' 'You may also change these, but **nothing captures them** — a rebuild or a migration will not carry the change, so make it only when asked and tell the operator you did:'
    printf '\n'
    printf '%s\n' "$writable" | while IFS= read -r path; do
      [ -n "$path" ] || continue
      printf -- '- `%s`\n' "$path"
    done
    printf '\n'
  fi

  printf '%s\n' 'Everything else is reference material. To change behavior that lives in code you do not own, use a hook, a filter, or a template override in the source above. If that is genuinely impossible, say so rather than editing outside the list.'
  printf '\n'
  printf '%s\n' '**Your edits are live the moment you save them.** There is no staging environment and no review gate between you and the public site, so verify each change — load the affected page or run the relevant WP-CLI command — before you leave it in place.'
}
