#!/bin/bash
# Skills: agent skill installation from git repos and the wp-coding-agents repo itself

# Install agent skills from a git repo.
# Clones the repo, copies directories containing SKILL.md to the target.
install_skills_from_repo() {
  local repo_url="$1"
  local label="${2:-skills}"

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} git clone --depth 1 $repo_url (extract skill dirs to $SKILLS_DIR)"
    return
  fi

  local tmp_dir
  tmp_dir=$(mktemp -d)
  if git clone --depth 1 "$repo_url" "$tmp_dir" 2>/dev/null; then
    for skill_dir in "$tmp_dir"/*/; do
      local skill_name
      skill_name=$(basename "$skill_dir")
      if [ -f "$skill_dir/SKILL.md" ]; then
        rm -rf "$SKILLS_DIR/$skill_name"
        cp -r "$skill_dir" "$SKILLS_DIR/$skill_name"
        log "  Installed skill: $skill_name"
      fi
    done
    rm -rf "$tmp_dir"
    log "$label installed (latest version)"
  else
    warn "Could not clone $label from $repo_url"
    rm -rf "$tmp_dir"
  fi
}

# Install skills shipped in this repo ($SCRIPT_DIR/skills/).
# These are the skills that ship with wp-coding-agents itself — e.g.
# upgrade-wp-coding-agents and wp-coding-agents-setup — so every install
# can run them without a manual copy step.
install_skills_from_local_repo() {
  local src_dir="$SCRIPT_DIR/skills"
  [ -d "$src_dir" ] || return

  if [ "$DRY_RUN" = true ]; then
    for skill_dir in "$src_dir"/*/; do
      [ -f "$skill_dir/SKILL.md" ] || continue
      echo -e "${BLUE}[dry-run]${NC} Would install in-repo skill: $(basename "$skill_dir") → $SKILLS_DIR/"
    done
    return
  fi

  local copied=0
  for skill_dir in "$src_dir"/*/; do
    local skill_name
    skill_name=$(basename "$skill_dir")
    if [ -f "$skill_dir/SKILL.md" ]; then
      rm -rf "$SKILLS_DIR/$skill_name"
      cp -r "$skill_dir" "$SKILLS_DIR/$skill_name"
      log "  Installed skill: $skill_name"
      copied=$((copied + 1))
    fi
  done
  if [ "$copied" -gt 0 ]; then
    log "wp-coding-agents in-repo skills installed ($copied)"
  fi
}

# Mirror every SKILL.md-containing subdir from $SKILLS_DIR into the
# persistent kimaki-config/skills/ dir. This is the durable source of
# truth that survives `npm update -g kimaki` wipes — kimaki/post-upgrade.sh
# reads from this path on every kimaki restart to restore the mirror copy
# at $(npm root -g)/kimaki/skills/.
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

  mkdir -p "$persistent_dir" 2>/dev/null || {
    warn "Could not create persistent skill source dir $persistent_dir — skipping mirror"
    return
  }

  local copied=0
  for skill_dir in "$SKILLS_DIR"/*/; do
    [ -d "$skill_dir" ] || continue
    local skill_name
    skill_name=$(basename "$skill_dir")
    if [ -f "$skill_dir/SKILL.md" ]; then
      rm -rf "$persistent_dir/$skill_name"
      cp -r "$skill_dir" "$persistent_dir/$skill_name"
      copied=$((copied + 1))
    fi
  done
  if [ "$copied" -gt 0 ]; then
    log "Skills mirrored to persistent source: $persistent_dir/ ($copied)"
    log "  post-upgrade.sh will restore these on every kimaki restart."
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

install_skills() {
  # Primary skills dir — set from the currently sourced runtime (drives the
  # summary output and the kimaki mirror source). Multi-runtime installs
  # populate every detected runtime's skills dir below, but the primary
  # stays the canonical one the rest of the script refers to.
  SKILLS_DIR="$(runtime_skills_dir)"

  if [ "$INSTALL_SKILLS" != true ]; then
    log "Phase 8.5: Skipping agent skills (--no-skills)"
    return
  fi

  log "Phase 8.5: Installing agent skills..."

  # Build the unique list of skills dirs to populate. claude-code and
  # studio-code both resolve to $SITE_PATH/.claude/skills, so de-dupe.
  local -a runtimes=("${DETECTED_RUNTIMES[@]:-$RUNTIME}")
  local -a skills_dirs=()
  local seen_dir rt dir
  for rt in "${runtimes[@]}"; do
    dir="$(_resolve_skills_dir_for_runtime "$rt")"
    [ -n "$dir" ] || continue
    local already=false
    for seen_dir in "${skills_dirs[@]}"; do
      [ "$seen_dir" = "$dir" ] && { already=true; break; }
    done
    [ "$already" = true ] || skills_dirs+=("$dir")
  done

  # Always guarantee the primary is in the list (for belt-and-braces when
  # RUNTIME was set explicitly but somehow isn't in DETECTED_RUNTIMES).
  local already=false
  for seen_dir in "${skills_dirs[@]}"; do
    [ "$seen_dir" = "$SKILLS_DIR" ] && { already=true; break; }
  done
  [ "$already" = true ] || skills_dirs+=("$SKILLS_DIR")

  if [ ${#skills_dirs[@]} -gt 1 ]; then
    log "  Detected ${#runtimes[@]} runtime(s): ${runtimes[*]}"
    log "  Populating ${#skills_dirs[@]} unique skills dir(s)"
  fi

  # Install into every detected runtime's skills dir.
  local target_dir
  for target_dir in "${skills_dirs[@]}"; do
    if [ ${#skills_dirs[@]} -gt 1 ]; then
      log "→ Installing skills into $target_dir"
    fi
    SKILLS_DIR="$target_dir"
    run_cmd mkdir -p "$SKILLS_DIR"

    install_skills_from_local_repo
    install_skills_from_repo "https://github.com/WordPress/agent-skills.git" "WordPress agent skills"
    install_skills_from_repo "https://github.com/Extra-Chill/data-machine-skills.git" "Data Machine skills"
  done

  # Reset SKILLS_DIR back to the primary for downstream consumers
  # (kimaki mirror source, print_skills_summary, summary.sh).
  SKILLS_DIR="$(runtime_skills_dir)"

  # Copy skills to Kimaki's directory if Kimaki is the chat bridge.
  # Kimaki overrides OpenCode's skill discovery to only look in its
  # own bundled skills dir, so the runtime skills dir alone isn't enough.
  if [ "$CHAT_BRIDGE" = "kimaki" ]; then
    if [ "$DRY_RUN" = true ]; then
      KIMAKI_SKILLS_DIR="/usr/lib/node_modules/kimaki/skills"
      echo -e "${BLUE}[dry-run]${NC} Would copy skills to $KIMAKI_SKILLS_DIR/ (if Kimaki installed)"
    elif command -v kimaki &> /dev/null; then
      KIMAKI_SKILLS_DIR="$(npm root -g 2>/dev/null)/kimaki/skills"
      if [ -d "$KIMAKI_SKILLS_DIR" ]; then
        for skill_dir in "$SKILLS_DIR"/*/; do
          skill_name=$(basename "$skill_dir")
          if [ -f "$skill_dir/SKILL.md" ]; then
            cp -r "$skill_dir" "$KIMAKI_SKILLS_DIR/$skill_name"
          fi
        done
        log "Skills also copied to Kimaki: $KIMAKI_SKILLS_DIR/"
      fi
    fi

    # Mirror skills into the persistent kimaki-config/skills/ dir so
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

  # Collect unique skills dirs across detected runtimes, same logic as
  # install_skills. Falls back to SKILLS_DIR if DETECTED_RUNTIMES is empty.
  local -a runtimes=("${DETECTED_RUNTIMES[@]:-$RUNTIME}")
  local -a skills_dirs=()
  local seen_dir rt dir
  for rt in "${runtimes[@]}"; do
    dir="$(_resolve_skills_dir_for_runtime "$rt")"
    [ -n "$dir" ] || continue
    local already=false
    for seen_dir in "${skills_dirs[@]}"; do
      [ "$seen_dir" = "$dir" ] && { already=true; break; }
    done
    [ "$already" = true ] || skills_dirs+=("$dir")
  done
  [ ${#skills_dirs[@]} -gt 0 ] || skills_dirs=("$SKILLS_DIR")

  for dir in "${skills_dirs[@]}"; do
    log "Skills installed to $dir/"
    if [ "$DRY_RUN" = false ]; then
      ls -1 "$dir" 2>/dev/null | while read -r skill; do
        log "  - $skill"
      done
    fi
  done
}
