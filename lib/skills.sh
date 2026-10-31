#!/bin/bash
# Retired managed skills.
#
# wp-coding-agents used to install an `upgrade-wp-coding-agents` skill: a
# runbook the agent followed to run upgrade.sh by hand. Upgrades are now
# deterministic: `roadie upgrade` / `/upgrade-and-restart` call the host's
# upgrade command (lib/self-upgrade.sh) through Roadie's host_upgrade hook.
# This file only removes copies earlier installs left in runtime skill dirs.
# Site-specific guidance belongs in the composed AGENTS.md.

WP_CODING_AGENTS_RETIRED_SKILLS=(upgrade-wp-coding-agents wp-coding-agents-setup)

# Pi discovers project skills here; no runtime dispatcher is needed.
_retired_skill_roots() {
  local root="${RUNTIME_PROJECT_ROOT:-${SITE_PATH:-}}"
  [ -n "$root" ] || return 0
  printf '%s\n' "$root/.pi/skills" "$root/.agents/skills"
}

remove_retired_skills() {
  local root skill
  while IFS= read -r root; do
    for skill in "${WP_CODING_AGENTS_RETIRED_SKILLS[@]}"; do
      [ -d "$root/$skill" ] || continue
      if [ "${DRY_RUN:-false}" = true ]; then
        echo -e "${BLUE}[dry-run]${NC} Would remove retired managed skill: $root/$skill"
        continue
      fi
      rm -rf "${root:?}/$skill"
      log "  Removed retired managed skill: $root/$skill"
      UPDATED_ITEMS+=("removed retired skill $skill")
    done
  done < <(_retired_skill_roots)
}
