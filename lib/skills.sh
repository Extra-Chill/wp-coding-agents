#!/bin/bash
# Upgrade skill installation from the wp-coding-agents repo itself.
# Site-specific WordPress, Data Machine, and Homeboy guidance belongs in the
# composed AGENTS.md, which is fresher than static external skill snapshots.

WP_CODING_AGENTS_SKILLS=(upgrade-wp-coding-agents)

is_wp_coding_agents_skill() {
  local candidate="$1"
  local skill

  for skill in "${WP_CODING_AGENTS_SKILLS[@]}"; do
    [ "$candidate" = "$skill" ] && return 0
  done

  return 1
}

# Install managed skills shipped in this repo ($SCRIPT_DIR/skills/).
# The installed set intentionally excludes setup. Setup is a pre-install entry
# point that should be used once from the operator's machine, then discarded.
# Installed agents only need the upgrade runbook for ongoing maintenance.
install_skills_from_local_repo() {
  local src_dir="$SCRIPT_DIR/skills"
  [ -d "$src_dir" ] || return

  if [ "$DRY_RUN" = true ]; then
    for skill_dir in "$src_dir"/*/; do
      local skill_name
      skill_name=$(basename "$skill_dir")
      [ -f "$skill_dir/SKILL.md" ] || continue
      is_wp_coding_agents_skill "$skill_name" || continue
      echo -e "${BLUE}[dry-run]${NC} Would install upgrade skill: $skill_name → $SKILLS_DIR/"
    done
    return
  fi

  local copied=0
  for skill_dir in "$src_dir"/*/; do
    local skill_name
    skill_name=$(basename "$skill_dir")
    if [ -f "$skill_dir/SKILL.md" ] && is_wp_coding_agents_skill "$skill_name"; then
      rm -rf "$SKILLS_DIR/$skill_name"
      cp -r "$skill_dir" "$SKILLS_DIR/$skill_name"
      # Skills dirs live under the web tree (.claude/skills, .opencode/skills,
      # .agents/skills) and get rewritten across setup/upgrade runs that may
      # each run as a different identity (root, opencode, www-data) — same
      # multi-writer problem as the mu-plugins, just for a directory tree
      # instead of a single file.
      service_dir_normalize_perms "$SKILLS_DIR/$skill_name"
      log "  Installed upgrade skill: $skill_name"
      copied=$((copied + 1))
    fi
  done
  if [ "$copied" -gt 0 ]; then
    log "wp-coding-agents upgrade skill installed ($copied)"
  fi
}

# Mirror wp-coding-agents-owned upgrade skill into the persistent
# kimaki-config/skills/ dir. This is the durable source of
# truth that survives `npm update -g kimaki` wipes. Kimaki discovers this
# managed source without a package-local duplicate.
#
# Path resolution matches the plugin-persistence pattern used elsewhere:
#   Local: $KIMAKI_DATA_DIR/kimaki-config/skills/ (defaults to ~/.kimaki/kimaki-config/skills/)
#   VPS:   /opt/kimaki-config/skills/
install_skills_to_persistent_source() {
  local persistent_dir
  if [ "$LOCAL_MODE" = true ]; then
    local data_dir="${KIMAKI_DATA_DIR:-$HOME/.kimaki}"
    persistent_dir="$data_dir/kimaki-config/skills"
  else
    persistent_dir="/opt/kimaki-config/skills"
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would mirror skills to persistent source: $persistent_dir/"
    return
  fi

  if [ "$(id -u)" -ne 0 ] && [ -e "$persistent_dir" ] && [ ! -w "$persistent_dir" ]; then
    local skill_dir skill_name
    for skill_dir in "$SCRIPT_DIR/skills"/*/; do
      [ -d "$skill_dir" ] || continue
      skill_name=$(basename "$skill_dir")
      if [ -f "$skill_dir/SKILL.md" ] && is_wp_coding_agents_skill "$skill_name"; then
        if [ ! -d "$persistent_dir/$skill_name" ] \
          || ! diff -qr "$skill_dir" "$persistent_dir/$skill_name" >/dev/null 2>&1; then
          error "Persistent Kimaki skill source requires root privileges to install or update"
        fi
      fi
    done
    log "Keeping current root-owned persistent Kimaki skill source"
    return
  fi

  mkdir -p "$persistent_dir" 2>/dev/null || {
    warn "Could not create persistent skill source dir $persistent_dir — skipping mirror"
    return
  }

  local copied=0
  for skill_dir in "$SCRIPT_DIR/skills"/*/; do
    [ -d "$skill_dir" ] || continue
    local skill_name
    skill_name=$(basename "$skill_dir")
    if [ -f "$skill_dir/SKILL.md" ] && is_wp_coding_agents_skill "$skill_name"; then
      rm -rf "$persistent_dir/$skill_name"
      cp -r "$skill_dir" "$persistent_dir/$skill_name"
      copied=$((copied + 1))
    fi
  done
  if [ "$copied" -gt 0 ]; then
    log "Upgrade skill mirrored to persistent source: $persistent_dir/ ($copied)"
    log "  post-upgrade.sh will restore it on every kimaki restart."
  fi
}

# Resolve the skills dir for a given runtime without mutating the currently
# sourced runtime functions permanently. We source the runtime file in a
# subshell, call its runtime_skills_dir(), and echo the result.
_resolve_skills_dir_for_runtime() {
  local rt="$1"
  local rt_file="$SCRIPT_DIR/runtimes/${rt}.sh"
  [ -f "$rt_file" ] || { echo ""; return 1; }
  (
    # shellcheck disable=SC1090
    source "$rt_file"
    runtime_skills_dir
  )
}

# Return whether a detected runtime discovers both skill directories. Runtime
# discovery roots may overlap even when their native install directories differ.
_managed_skill_dirs_overlap() {
  local first_dir="$1" second_dir="$2"
  local rt rt_file discovery_dir has_first has_second

  for rt in "${DETECTED_RUNTIMES[@]:-$RUNTIME}"; do
    rt_file="$SCRIPT_DIR/runtimes/${rt}.sh"
    [ -f "$rt_file" ] || continue
    has_first=false
    has_second=false

    while IFS= read -r discovery_dir; do
      [ "$discovery_dir" = "$first_dir" ] && has_first=true
      [ "$discovery_dir" = "$second_dir" ] && has_second=true
    done < <(
      # shellcheck disable=SC1090
      source "$rt_file"
      runtime_skill_discovery_dirs
    )

    [ "$has_first" = true ] && [ "$has_second" = true ] && return 0
  done

  return 1
}

# Resolve both the runtime roots that may contain managed skills and the
# canonical targets to populate. Select the first native target in each set of
# overlapping discovery roots.
_resolve_managed_skill_dirs() {
  local -a runtimes=("${DETECTED_RUNTIMES[@]:-$RUNTIME}")
  local rt dir seen_dir target already overlaps

  WP_CODING_AGENTS_SKILL_ROOTS=()
  WP_CODING_AGENTS_SKILL_TARGETS=()

  for rt in "${runtimes[@]}"; do
    dir="$(_resolve_skills_dir_for_runtime "$rt")"
    [ -n "$dir" ] || continue

    already=false
    for seen_dir in "${WP_CODING_AGENTS_SKILL_ROOTS[@]}"; do
      [ "$seen_dir" = "$dir" ] && { already=true; break; }
    done
    [ "$already" = true ] || WP_CODING_AGENTS_SKILL_ROOTS+=("$dir")

    overlaps=false
    for target in "${WP_CODING_AGENTS_SKILL_TARGETS[@]}"; do
      _managed_skill_dirs_overlap "$target" "$dir" && { overlaps=true; break; }
    done
    [ "$overlaps" = true ] || WP_CODING_AGENTS_SKILL_TARGETS+=("$dir")
  done

  [ ${#WP_CODING_AGENTS_SKILL_TARGETS[@]} -gt 0 ] \
    || WP_CODING_AGENTS_SKILL_TARGETS=("$(runtime_skills_dir)")
  SKILLS_DIR="${WP_CODING_AGENTS_SKILL_TARGETS[0]}"
}

_cleanup_managed_skill_duplicates() {
  local root target is_target

  for root in "${WP_CODING_AGENTS_SKILL_ROOTS[@]}"; do
    if [ -d "$root/wp-coding-agents-setup" ]; then
      if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[dry-run]${NC} Would remove retired managed skill: $root/wp-coding-agents-setup"
      else
        rm -rf "$root/wp-coding-agents-setup"
        log "  Removed retired managed skill: $root/wp-coding-agents-setup"
      fi
    fi

    is_target=false
    for target in "${WP_CODING_AGENTS_SKILL_TARGETS[@]}"; do
      [ "$root" = "$target" ] && { is_target=true; break; }
    done
    if [ "$is_target" = false ] && [ -d "$root/upgrade-wp-coding-agents" ]; then
      if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[dry-run]${NC} Would remove noncanonical managed skill: $root/upgrade-wp-coding-agents"
      else
        rm -rf "$root/upgrade-wp-coding-agents"
        log "  Removed noncanonical managed skill: $root/upgrade-wp-coding-agents"
      fi
    fi
  done
}

install_skills() {
  _resolve_managed_skill_dirs

  if [ "$INSTALL_SKILLS" != true ]; then
    log "Phase 8.5: Skipping upgrade skill (--no-skills)"
    return
  fi

  log "Phase 8.5: Installing upgrade skill..."

  if [ ${#WP_CODING_AGENTS_SKILL_TARGETS[@]} -gt 1 ]; then
    log "  Populating ${#WP_CODING_AGENTS_SKILL_TARGETS[@]} unique skills dir(s)"
  fi

  # Install the managed upgrade skill into each canonical runtime target.
  local target_dir
  for target_dir in "${WP_CODING_AGENTS_SKILL_TARGETS[@]}"; do
    if [ ${#WP_CODING_AGENTS_SKILL_TARGETS[@]} -gt 1 ]; then
      log "→ Installing skills into $target_dir"
    fi
    SKILLS_DIR="$target_dir"
    run_cmd mkdir -p "$SKILLS_DIR"

    install_skills_from_local_repo
  done

  # Keep existing fallback copies until the canonical install succeeds.
  _cleanup_managed_skill_duplicates

  SKILLS_DIR="${WP_CODING_AGENTS_SKILL_TARGETS[0]}"

  if [ "$CHAT_BRIDGE" = "kimaki" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would sync Kimaki's persistent skill source"
    fi

    # Mirror the upgrade skill into the persistent kimaki-config/skills/ dir so
    # post-upgrade.sh can restore them on every kimaki restart after
    # `npm update -g kimaki` wipes $(npm root -g)/kimaki/skills/.
    # Path mirrors the plugin-persistence pattern:
    #   Local: $KIMAKI_DATA_DIR/kimaki-config/skills/ (defaults to ~/.kimaki/kimaki-config/skills/)
    #   VPS:   /opt/kimaki-config/skills/
    install_skills_to_persistent_source
  fi
}

print_skills_summary() {
  echo ""

  _resolve_managed_skill_dirs

  local dir
  for dir in "${WP_CODING_AGENTS_SKILL_TARGETS[@]}"; do
    log "Managed upgrade skill target: $dir/"
    if [ "$DRY_RUN" = false ]; then
      ls -1 "$dir" 2>/dev/null | while read -r skill; do
        log "  - $skill"
      done
    fi
  done
}
