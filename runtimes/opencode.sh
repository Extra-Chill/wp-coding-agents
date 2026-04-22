#!/bin/bash
# Runtime: OpenCode — install, config generation, AGENTS.md, MCP merge

runtime_install() {
  log "Phase 7: Installing OpenCode..."

  if ! command -v opencode &> /dev/null || [ "$DRY_RUN" = true ]; then
    run_cmd npm install -g opencode-ai
  else
    log "OpenCode already installed: $(opencode --version 2>/dev/null || echo 'unknown')"
  fi

  _install_opencode_wrapper
  _patch_claude_auth_plugin
}

# Install a wrapper script that syncs Kimaki's Anthropic OAuth credentials
# into ~/.claude/.credentials.json for opencode-claude-auth to consume.
# On VPS, Kimaki manages token refresh — the wrapper keeps the claude creds
# file in sync before each opencode invocation.
_install_opencode_wrapper() {
  # Only needed when kimaki is the chat bridge (it manages OAuth tokens)
  if [ "$CHAT_BRIDGE" != "kimaki" ]; then
    return
  fi

  if [ "$LOCAL_MODE" = true ]; then
    # Local installs don't use the wrapper — credentials come from the user's
    # own claude auth or keychain directly.
    return
  fi

  local OPENCODE_BIN
  OPENCODE_BIN=$(command -v opencode 2>/dev/null || echo "/usr/bin/opencode")

  # Don't wrap if opencode is already a wrapper script (re-runs)
  if head -1 "$OPENCODE_BIN" 2>/dev/null | grep -q "bash"; then
    log "OpenCode wrapper already installed — skipping"
    return
  fi

  # Find the real opencode binary (after npm install, it's in node_modules)
  local REAL_BIN
  REAL_BIN=$(readlink -f "$OPENCODE_BIN" 2>/dev/null || echo "$OPENCODE_BIN")
  # If the resolved path is still a wrapper, dig deeper
  if head -1 "$REAL_BIN" 2>/dev/null | grep -q "bash"; then
    REAL_BIN="/usr/lib/node_modules/opencode-ai/bin/opencode"
  fi

  if [ ! -f "$REAL_BIN" ]; then
    warn "Could not find real opencode binary — skipping wrapper install"
    return
  fi

  log "Installing OpenCode credential sync wrapper..."

  local WRAPPER_CONTENT='#!/usr/bin/env bash
set -euo pipefail

# Syncs Anthropic credentials from Kimaki'\''s account store into the format
# opencode-claude-auth reads (~/.claude/.credentials.json). Kimaki manages
# OAuth token refresh — this wrapper forwards fresh tokens on each invocation.

KIMAKI_ACCOUNTS="${HOME}/.local/share/opencode/anthropic-oauth-accounts.json"
CLAUDE_CREDENTIALS="${HOME}/.claude/.credentials.json"

if [[ -f "$KIMAKI_ACCOUNTS" ]] && command -v node >/dev/null 2>&1; then
  node -e '"'"'
    const fs = require("fs");
    const path = require("path");
    try {
      const accounts = JSON.parse(fs.readFileSync(process.env.KIMAKI_ACCOUNTS, "utf-8"));
      if (!accounts.accounts || accounts.accounts.length === 0) process.exit(0);
      const idx = accounts.activeIndex ?? 0;
      const acct = accounts.accounts[idx] ?? accounts.accounts[0];
      if (!acct || !acct.refresh) process.exit(0);
      const claudePath = process.env.CLAUDE_CREDENTIALS;
      let creds = {};
      try { creds = JSON.parse(fs.readFileSync(claudePath, "utf-8")); } catch {}
      const kimakiExpires = acct.expires || 0;
      const claudeExpires = creds.claudeAiOauth?.expiresAt || 0;
      if (kimakiExpires > claudeExpires) {
        creds.claudeAiOauth = creds.claudeAiOauth || {};
        creds.claudeAiOauth.refreshToken = acct.refresh;
        creds.claudeAiOauth.expiresAt = acct.expires;
        if (acct.access) creds.claudeAiOauth.accessToken = acct.access;
        creds.claudeAiOauth.subscriptionType = "max";
        creds.claudeAiOauth.scopes = ["user:file_upload","user:inference","user:mcp_servers","user:profile","user:sessions:claude_code"];
        creds.claudeAiOauth.rateLimitTier = "default_claude_max_20x";
        fs.mkdirSync(path.dirname(claudePath), { recursive: true });
        fs.writeFileSync(claudePath, JSON.stringify(creds, null, 2), { mode: 0o600 });
      }
    } catch {}
  '"'"' 2>/dev/null || true
fi

# Legacy sync: claude creds → opencode auth.json (fallback for built-in auth)
AUTH_DST="${HOME}/.local/share/opencode/auth.json"
if [[ -f "$CLAUDE_CREDENTIALS" ]] && command -v jq >/dev/null 2>&1; then
  mkdir -p "$(dirname "$AUTH_DST")"
  jq "{anthropic:{type:\"oauth\",refresh:(.claudeAiOauth.refreshToken//error(\"missing\")),access:(.claudeAiOauth.accessToken//error(\"missing\")),expires:(.claudeAiOauth.expiresAt//error(\"missing\"))}}" "$CLAUDE_CREDENTIALS" > "${AUTH_DST}.tmp" 2>/dev/null && mv "${AUTH_DST}.tmp" "$AUTH_DST"
fi

exec '"${REAL_BIN}"' "$@"
'

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would install OpenCode wrapper at $OPENCODE_BIN"
  else
    echo "$WRAPPER_CONTENT" > "$OPENCODE_BIN"
    chmod +x "$OPENCODE_BIN"
    log "Installed credential sync wrapper at $OPENCODE_BIN → $REAL_BIN"
  fi
}

# Patch opencode-claude-auth to use PascalCase mcp_ tool names.
#
# Anthropic's billing validator rejects lowercase mcp_-prefixed tool names
# (e.g. mcp_bash) as non-Claude-Code clients, causing 400 "out of extra usage"
# errors. Real Claude Code uses PascalCase (mcp_Bash, mcp_Read). This patch
# applies the same convention until the upstream plugin releases a fix.
#
# Safe to re-run: detects if already patched and skips.
# Ref: https://github.com/griffinmartin/opencode-claude-auth/issues/188
#      https://github.com/griffinmartin/opencode-claude-auth/pull/191
_patch_claude_auth_plugin() {
  if [ ! -f "$SCRIPT_DIR/lib/patch-claude-auth.py" ]; then
    warn "patch-claude-auth.py not found — skipping auth plugin patch"
    return
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would patch opencode-claude-auth with PascalCase tool names"
    return
  fi

  log "Checking opencode-claude-auth for PascalCase patch..."
  python3 "$SCRIPT_DIR/lib/patch-claude-auth.py" 2>/dev/null

  if [ $? -eq 0 ]; then
    log "opencode-claude-auth: PascalCase tool names applied (mcp_Bash, mcp_Read, etc.)"
  else
    warn "opencode-claude-auth patch failed or plugin not yet cached — will retry on next run"
  fi
}

runtime_discover_dm_paths() {
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/wp-config.php" ]; then
    AGENT_FLAG=""
    if [ -n "$AGENT_SLUG" ]; then
      AGENT_FLAG="--agent=$AGENT_SLUG"
    fi
    DM_PATHS_RAW=$(wp_cmd datamachine agent paths --format=json $AGENT_FLAG 2>/dev/null || echo "")
    # SQLite translation layer may emit HTML error noise — extract only JSON
    DM_PATHS_JSON=$(echo "$DM_PATHS_RAW" | sed -n '/^{/,/^}/p')
    if [ -z "$DM_PATHS_JSON" ]; then
      error "'$WP_CMD datamachine agent paths' returned no JSON — is Data Machine active and agent created?"
    fi
    DM_AGENT_FILES=$(echo "$DM_PATHS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for f in data.get('relative_files', []):
    print(f)
")
    log "Agent files discovered via '$WP_CMD datamachine agent paths${AGENT_FLAG:+ ($AGENT_FLAG)}'"
  else
    # Dry-run: use placeholder paths
    DM_DRY_SLUG="${AGENT_SLUG:-AGENT_SLUG}"
    DM_AGENT_FILES="wp-content/uploads/datamachine-files/shared/SITE.md
wp-content/uploads/datamachine-files/agents/${DM_DRY_SLUG}/SOUL.md
wp-content/uploads/datamachine-files/agents/${DM_DRY_SLUG}/MEMORY.md
wp-content/uploads/datamachine-files/users/USER_ID/USER.md"
    log "Dry-run: using placeholder agent paths (slug: $DM_DRY_SLUG)"
  fi

  # Build prompt from discovered files
  OPENCODE_PROMPT="{file:./AGENTS.md}"
  while IFS= read -r rel_path; do
    OPENCODE_PROMPT="$OPENCODE_PROMPT\\\\n{file:./${rel_path}}"
  done <<< "$DM_AGENT_FILES"
}

runtime_generate_config() {
  # Skip if already exists — safe for re-runs
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/opencode.json" ]; then
    log "opencode.json already exists — skipping (delete to regenerate)"
    return
  fi

  log "Generating opencode.json..."

  OPENCODE_JSON="{"
  OPENCODE_JSON="$OPENCODE_JSON\n  \"\$schema\": \"https://opencode.ai/config.json\""

  if [ -n "$OPENCODE_MODEL" ]; then
    OPENCODE_JSON="$OPENCODE_JSON,\n  \"model\": \"${OPENCODE_MODEL}\""
  fi
  if [ -n "$OPENCODE_SMALL_MODEL" ]; then
    OPENCODE_JSON="$OPENCODE_JSON,\n  \"small_model\": \"${OPENCODE_SMALL_MODEL}\""
  fi

  # OpenCode plugins
  OPENCODE_PLUGINS=""

  # opencode-claude-auth: Claude Max/Pro OAuth auth + billing header injection
  # + system prompt relocation to avoid Anthropic's third-party app detection.
  #
  # Skip when CHAT_BRIDGE=kimaki. Kimaki v0.6.0+ ships a built-in
  # AnthropicAuthPlugin that handles the same concerns (OAuth, token refresh,
  # request/response rewriting, multi-account rotation). Loading both plugins
  # causes them to compete for the same `anthropic` auth provider in OpenCode.
  # See Extra-Chill/wp-coding-agents#51.
  if [ "$CHAT_BRIDGE" != "kimaki" ]; then
    OPENCODE_PLUGINS="${OPENCODE_PLUGINS}\n    \"opencode-claude-auth@latest\","
  fi

  # DM context filter + agent sync — only when DM memory is surfaced via Kimaki.
  if [ "$CHAT_BRIDGE" = "kimaki" ]; then
    if [ "$LOCAL_MODE" = true ]; then
      KIMAKI_PLUGINS_DIR="$(npm root -g 2>/dev/null)/kimaki/plugins"
      if [ "$DRY_RUN" = false ] && [ -d "$(dirname "$KIMAKI_PLUGINS_DIR")" ]; then
        mkdir -p "$KIMAKI_PLUGINS_DIR"
        cp "$SCRIPT_DIR/kimaki/plugins/dm-context-filter.ts" "$KIMAKI_PLUGINS_DIR/" 2>/dev/null || true
        cp "$SCRIPT_DIR/kimaki/plugins/dm-agent-sync.ts" "$KIMAKI_PLUGINS_DIR/" 2>/dev/null || true
      fi
    else
      KIMAKI_PLUGINS_DIR="/opt/kimaki-config/plugins"
    fi
    OPENCODE_PLUGINS="${OPENCODE_PLUGINS}\n    \"${KIMAKI_PLUGINS_DIR}/dm-context-filter.ts\","
    OPENCODE_PLUGINS="${OPENCODE_PLUGINS}\n    \"${KIMAKI_PLUGINS_DIR}/dm-agent-sync.ts\","
  fi

  if [ -n "$OPENCODE_PLUGINS" ]; then
    # Remove trailing comma from last plugin entry
    OPENCODE_PLUGINS=$(echo "$OPENCODE_PLUGINS" | sed 's/,$//')
    OPENCODE_JSON="$OPENCODE_JSON,\n  \"plugin\": [${OPENCODE_PLUGINS}\n  ]"
  fi

  # Agent prompt config
  OPENCODE_JSON="$OPENCODE_JSON,\n  \"agent\": {"
  OPENCODE_JSON="$OPENCODE_JSON\n    \"build\": {"
  OPENCODE_JSON="$OPENCODE_JSON\n      \"prompt\": \"${OPENCODE_PROMPT}\""
  OPENCODE_JSON="$OPENCODE_JSON\n    },"
  OPENCODE_JSON="$OPENCODE_JSON\n    \"plan\": {"
  OPENCODE_JSON="$OPENCODE_JSON\n      \"prompt\": \"${OPENCODE_PROMPT}\""
  OPENCODE_JSON="$OPENCODE_JSON\n    }"
  OPENCODE_JSON="$OPENCODE_JSON\n  }"

  # Permission: allow DM workspace as external directory
  OPENCODE_JSON="$OPENCODE_JSON,\n  \"permission\": {"
  OPENCODE_JSON="$OPENCODE_JSON\n    \"external_directory\": {"
  OPENCODE_JSON="$OPENCODE_JSON\n      \"${DM_WORKSPACE_DIR}/**\": \"allow\""
  OPENCODE_JSON="$OPENCODE_JSON\n    }"
  OPENCODE_JSON="$OPENCODE_JSON\n  }"

  OPENCODE_JSON="$OPENCODE_JSON\n}"

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would write to $SITE_PATH/opencode.json"
  else
    echo -e "$OPENCODE_JSON" > "$SITE_PATH/opencode.json"
  fi
}

runtime_generate_instructions() {
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/AGENTS.md" ]; then
    log "Phase 8: AGENTS.md already exists — skipping (delete to regenerate)"
    return
  fi

  log "Phase 8: Generating AGENTS.md..."

  # Compose from Data Machine's SectionRegistry. DM is mandatory, and compose
  # handles WP-CLI prefix resolution, multisite detection, and plugin sections
  # (intelligence, etc.) automatically at runtime.
  if [ "$DRY_RUN" = false ]; then
    if wp_cmd datamachine agent compose AGENTS.md 2>/dev/null; then
      log "AGENTS.md composed from SectionRegistry"
      return
    fi
    warn "Compose failed — falling back to static template"
  fi

  # Fallback for dry-run or compose failure: ship a minimal static template.
  local agents_tmpl="$SCRIPT_DIR/workspace/AGENTS.md"
  if [ ! -f "$agents_tmpl" ]; then
    error "AGENTS.md template not found at $agents_tmpl"
  fi

  local wp_cli_display="wp"
  if [ "$IS_STUDIO" = true ]; then
    wp_cli_display="studio wp"
  elif [ "$LOCAL_MODE" = false ]; then
    wp_cli_display="wp $WP_ROOT_FLAG --path=$SITE_PATH"
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would generate AGENTS.md from template"
  else
    sed "s|{{WP_CLI_CMD}}|$wp_cli_display|g" "$agents_tmpl" > "$SITE_PATH/AGENTS.md"
  fi
}

runtime_merge_mcp_servers() {
  if [ -z "${MCP_SERVERS:-}" ] || [ ! -f "$SITE_PATH/opencode.json" ]; then
    return
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would merge MCP_SERVERS into opencode.json"
    return
  fi

  command -v jq &>/dev/null || error "MCP_SERVERS requires jq"
  log "Merging MCP servers into opencode.json..."
  jq --argjson mcp "$MCP_SERVERS" '.mcp = $mcp' "$SITE_PATH/opencode.json" \
    > "$SITE_PATH/opencode.json.tmp" \
    && mv "$SITE_PATH/opencode.json.tmp" "$SITE_PATH/opencode.json"
}

runtime_install_hooks() {
  return
}

runtime_skills_dir() {
  echo "$SITE_PATH/.opencode/skills"
}

runtime_print_summary() {
  echo "OpenCode:"
  echo "  Config:   $SITE_PATH/opencode.json"
  if [ -n "$OPENCODE_MODEL" ]; then
    echo "  Model:    $OPENCODE_MODEL"
  else
    echo "  Model:    (OpenCode default — zen free models)"
  fi
  echo ""
}
