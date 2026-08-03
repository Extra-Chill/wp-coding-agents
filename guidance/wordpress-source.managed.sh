#!/bin/bash
# guidance/wordpress-source.managed.sh — installed WordPress source, managed posture.
#
# Managed agentic hosting: the agent edits the site's OWN theme and plugins in
# place at the owner's request. There is no workspace, no git, and no GitHub in
# its world.
#
# TWO RULES FOR THIS FILE.
#
# 1. Enumerate, never generalise. The editable set comes from
#    source_policy_owned_sources and is printed path by path. An earlier version
#    said "this site's theme and plugins" while the policy opened
#    `wp-content/plugins/**` wholesale — see #318.
#
# 2. Assert only what wp-coding-agents actually knows. This text ships to EVERY
#    managed install, so it must not describe one site's stack as if it were
#    universal. An earlier version named "commerce and payment code" and "the
#    site's ability to take money" (there may be no store), called the remaining
#    plugins "the runtime that gives you memory and tools" (that is this
#    install's happenstance), and listed a specific set of never-captured paths
#    copied from one operator's harvest excludes — a config this tool does not
#    own and cannot read. Describe the CATEGORY and the REASON; leave the
#    specifics to the operator. An earlier version of this file said "this site's
# theme and plugins" while the permission layer opened `wp-content/plugins/**`
# wholesale — which on a real install meant WooCommerce, a payment gateway, and
# the agent's own Data Machine runtime. Prose that generalises where the policy
# enumerates is how that gap opens. If a path is not in the declared set it is
# not editable, and this section must say so by name.

guidance_id() { printf 'wordpress-source'; }
guidance_priority() { printf '1'; }
guidance_label() { printf 'WordPress Source'; }
guidance_description() { printf 'Editable owned source, read-only everything else, and the live-production contract.'; }
guidance_freshness() { printf 'conditional'; }
guidance_conditions() { printf 'Registered on managed-posture installations; the editable path list is generated from the declared managed sources.'; }

guidance_render() {
  local owned
  owned="$(source_policy_owned_sources)"

  printf '%s\n' '## WordPress Source'
  printf '\n'

  if [ -z "$owned" ]; then
    # Fail closed, loudly. Never imply a directory is editable.
    printf '%s\n' 'This install declares no editable source. Every file under `wp-content/` and `wp-includes/` is **read-only** to you.'
    printf '\n'
    printf '%s\n' 'Read them freely to verify APIs, hooks, and runtime behavior. If a task requires changing code, stop and tell the operator that no editable source is configured.'
    return 0
  fi

  printf '%s\n' 'You edit this site directly. There is no separate checkout, no workspace, and no pull request step.'
  printf '\n'
  printf '%s\n' '### Editable — this is the complete list'
  printf '\n'
  printf '%s\n' 'These are the source trees this site owns. Nothing else is editable, no matter where it lives:'
  printf '\n'
  printf '%s\n' "$owned" | while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf -- '- `%s/`\n' "$path"
  done
  printf '\n'
  printf '%s\n' '### Read-only — everything else'
  printf '\n'
  printf '%s\n' 'Everything else installed here belongs to somebody else. Read it freely to verify APIs, hooks, conventions, and runtime behavior; never edit it:'
  printf '\n'
  printf '%s\n' '- `wp-includes/` — WordPress core.'
  printf '%s\n' '- The rest of `wp-content/plugins/` — plugins this site did not author, including whatever this agent itself depends on.'
  printf '%s\n' '- The rest of `wp-content/themes/` — themes this site did not author.'
  printf '\n'
  printf '%s\n' 'Two reasons, both independent of what any particular plugin does: an update overwrites your change, and nothing captures it, so the work is lost either way.'
  printf '\n'
  printf '%s\n' 'To change behavior that lives in code you may not edit, change this site'"'"'s own theme or plugin instead — a hook, a filter, or a template override. If that is genuinely impossible, say so rather than editing outside the list.'
  printf '\n'
  printf '%s\n' '### Working on production'
  printf '\n'
  printf '%s\n' '- **Your edits are live the moment you save them.** There is no staging environment, no review gate, and no deploy step between you and the public site. A syntax error is a down site.'
  printf '%s\n' '- **Verify before you leave a change in place.** Load the affected page or run the relevant WP-CLI command. You are the only check that runs before visitors see it.'
  printf '%s\n' '- **Work is unbacked until it is captured.** The editable list above is what the operator declared as this site'"'"'s own source, and it is captured out-of-band on a schedule the operator owns. Between your edit and the next capture, the live file is the only copy.'
  printf '%s\n' '- **Rollback is an operator action.** You cannot restore a previous capture yourself. If something breaks and you cannot fix it forward, say so plainly and immediately rather than continuing to edit.'
  printf '\n'
  printf '%s\n' '### Installed and generated files are not source'
  printf '\n'
  printf '%s\n' 'Even inside the editable list, not every file is authored source. Dependency trees, lockfiles, and build output are installed or generated from something else, and a capture will usually skip them — so editing them in place is work that quietly disappears.'
  printf '\n'
  printf '%s\n' 'If a task seems to require changing one, stop and ask the operator which paths this site actually captures. Do not assume. The answer belongs to the operator'"'"'s capture configuration, not to you.'
}
