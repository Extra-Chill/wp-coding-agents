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

install_skills() {
  SKILLS_DIR="$(runtime_skills_dir)"

  if [ "$INSTALL_SKILLS" = true ]; then
    log "Phase 8.5: Installing agent skills..."
    run_cmd mkdir -p "$SKILLS_DIR"

    install_skills_from_local_repo

    install_skills_from_repo "https://github.com/WordPress/agent-skills.git" "WordPress agent skills"

    if [ "$INSTALL_DATA_MACHINE" = true ]; then
      install_skills_from_repo "https://github.com/Extra-Chill/data-machine-skills.git" "Data Machine skills"
    fi

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
          warn "Note: Kimaki upgrades (npm update -g kimaki) will remove these. Re-run --skills-only after upgrading."
        fi
      fi
    fi
  else
    log "Phase 8.5: Skipping agent skills (--no-skills)"
  fi
}

print_skills_summary() {
  echo ""
  log "Skills installed to $SKILLS_DIR/"
  if [ "$DRY_RUN" = false ]; then
    ls -1 "$SKILLS_DIR" 2>/dev/null | while read -r skill; do
      log "  - $skill"
    done
  fi
}
