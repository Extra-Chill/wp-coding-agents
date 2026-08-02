#!/bin/bash
# guidance/wordpress-source.managed.sh — installed WordPress source, managed posture.
#
# Managed agentic hosting: the agent edits the site's OWN theme and plugins in
# place at the owner's request. There is no workspace, no git, and no GitHub in
# its world.
#
# The editable set is enumerated from source_policy_owned_sources, never
# described as a directory. An earlier version of this file said "this site's
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
  printf '%s\n' 'Read these to verify APIs, hooks, conventions, and runtime behavior. Never edit them:'
  printf '\n'
  printf '%s\n' '- `wp-includes/` — WordPress core.'
  printf '%s\n' '- The rest of `wp-content/plugins/` — third-party plugins, including commerce and payment code, and the runtime that gives you memory and tools. Editing these breaks your own environment or the site'"'"'s ability to take money, and an update erases the change anyway.'
  printf '%s\n' '- The rest of `wp-content/themes/` — bundled and third-party themes.'
  printf '\n'
  printf '%s\n' 'To change behavior that lives in code you may not edit, change the site'"'"'s own theme or plugin instead — a hook, a filter, or a template override. If that is genuinely impossible, say so rather than editing outside the list.'
  printf '\n'
  printf '%s\n' '### Working on production'
  printf '\n'
  printf '%s\n' '- **Your edits are live the moment you save them.** There is no staging environment, no review gate, and no deploy step between you and the public site. A syntax error is a down site.'
  printf '%s\n' '- **Verify before you leave a change in place.** Load the affected page or run the relevant WP-CLI command. You are the only check that runs before visitors see it.'
  printf '%s\n' '- **Work is unbacked until it is captured.** The editable list above is exactly what the operator'"'"'s out-of-band capture records, and each capture is a restore point. Between your edit and the next capture, the live file is the only copy.'
  printf '%s\n' '- **Rollback is an operator action.** You cannot restore a previous capture yourself. If something breaks and you cannot fix it forward, say so plainly and immediately rather than continuing to edit.'
  printf '\n'
  printf '%s\n' '### Changes that are never captured'
  printf '\n'
  printf '%s\n' 'Dependency trees, lockfiles, and build output are installed or generated rather than authored, so a capture skips them even inside the editable list. Editing them produces a change that is **never recorded and is destroyed by the next deploy**:'
  printf '\n'
  printf '%s\n' '- `vendor/` and `node_modules/` — installed dependency trees'
  printf '%s\n' '- `composer.lock`, `package-lock.json`, `package.json` — dependency manifests'
  printf '%s\n' '- generated build output'
  printf '\n'
  printf '%s\n' 'If a task genuinely requires changing one of these, stop and tell the operator. It needs to happen in the source repository, not here.'
}
