#!/bin/bash
# lib/runtime-signature.sh — Cleanup for the retired DMC worktree registry.
#
# Runtime signature and context-projection hooks were consumed only by Data
# Machine Code. Homeboy has no equivalent WordPress hook contract, so do not
# rename those hooks into an unsupported Homeboy namespace. Remove the generated
# registry left by previous installs instead.

runtime_signature_mu_plugin_path() {
  [ -n "${SITE_PATH:-}" ] || return 1
  printf '%s' "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-runtimes.php"
}

runtime_signature_cleanup_retired_mu_plugin() {
  local file
  file="$(runtime_signature_mu_plugin_path)" || return 0
  [ -e "$file" ] || return 0

  if ! grep -q 'datamachine_code_worktree_runtime_signatures' "$file"; then
    if [ "${DRY_RUN:-false}" = true ]; then warn "Would preserve unknown runtime registry at $file (missing wp-coding-agents DMC marker)"; else warn "Preserving unknown runtime registry at $file (missing wp-coding-agents DMC marker)"; fi
    return 1
  fi

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE:-}[dry-run]${NC:-} Would remove installer-owned retired runtime registry at $file"
    return 0
  fi

  rm -f "$file"
  UPDATED_ITEMS+=("removed retired runtime registry")
}
