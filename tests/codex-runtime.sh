#!/bin/bash
# tests/codex-runtime.sh — Regression coverage for the Codex runtime adapter.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export SITE_PATH="$TMP/site"
export DRY_RUN=false
export IS_STUDIO=false
export LOCAL_MODE=true
export WP_ROOT_FLAG=
export WP_CMD=wp
export AGENT_SLUG=builder
mkdir -p "$SITE_PATH/wp-content/mu-plugins"
touch "$SITE_PATH/wp-config.php"
mkdir -p "$SITE_PATH/wp-content/uploads/datamachine-files/shared"
mkdir -p "$SITE_PATH/wp-content/uploads/datamachine-files/agents/builder"
mkdir -p "$SITE_PATH/wp-content/uploads/datamachine-files/users/1"
printf 'site context sentinel\n' > "$SITE_PATH/wp-content/uploads/datamachine-files/shared/SITE.md"
printf 'rules context sentinel\n' > "$SITE_PATH/wp-content/uploads/datamachine-files/shared/RULES.md"
printf 'soul context sentinel\n' > "$SITE_PATH/wp-content/uploads/datamachine-files/agents/builder/SOUL.md"
printf 'user context sentinel\n' > "$SITE_PATH/wp-content/uploads/datamachine-files/users/1/USER.md"
printf 'memory context sentinel\n' > "$SITE_PATH/wp-content/uploads/datamachine-files/agents/builder/MEMORY.md"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/runtime-signature.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtimes/codex.sh"

UPDATED_ITEMS=()

sync_homeboy_availability() { :; }
wp_cmd() {
  case "$1 $2 $3" in
    "datamachine memory injectable-files")
      cat <<'JSON'
[
  {"path":"wp-content/uploads/datamachine-files/shared/SITE.md"},
  {"path":"wp-content/uploads/datamachine-files/shared/RULES.md"},
  {"path":"wp-content/uploads/datamachine-files/agents/builder/SOUL.md"},
  {"path":"wp-content/uploads/datamachine-files/users/1/USER.md"},
  {"path":"wp-content/uploads/datamachine-files/agents/builder/MEMORY.md"}
]
JSON
      return 0
      ;;
    "datamachine memory compose")
      return 1
      ;;
  esac
  return 1
}

FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }

if [ "$(runtime_skills_dir)" = "$SITE_PATH/.agents/skills" ]; then
  pass "skills install target is project-local .agents/skills"
else
  fail "skills install target is project-local .agents/skills"
fi

runtime_discover_dm_paths

cat > "$SITE_PATH/AGENTS.md" <<'EOF_AGENTS'
# Existing shared instructions

<!-- WP_CODING_AGENTS_CODEX_MEMORY_START -->
## Data Machine Memory

legacy inline block
<!-- WP_CODING_AGENTS_CODEX_MEMORY_END -->
EOF_AGENTS
runtime_generate_instructions

if grep -q "# Existing shared instructions" "$SITE_PATH/AGENTS.md" && ! grep -q "WP_CODING_AGENTS_CODEX_MEMORY_START" "$SITE_PATH/AGENTS.md"; then
  pass "existing AGENTS.md preserved and legacy Codex memory block removed"
else
  fail "existing AGENTS.md preserved and legacy Codex memory block removed"
fi

if [ -f "$SITE_PATH/AGENTS.override.md" ] && grep -q "# Existing shared instructions" "$SITE_PATH/AGENTS.override.md" && grep -q "WP_CODING_AGENTS_CODEX_MEMORY_START" "$SITE_PATH/AGENTS.override.md"; then
  pass "Codex AGENTS.override.md mirrors shared instructions and memory block"
else
  fail "Codex AGENTS.override.md mirrors shared instructions and memory block"
fi

if grep -q "site context sentinel" "$SITE_PATH/AGENTS.override.md" && grep -q "memory context sentinel" "$SITE_PATH/AGENTS.override.md"; then
  pass "Codex override includes Data Machine memory file contents"
else
  fail "Codex override includes Data Machine memory file contents"
fi

rm -f "$SITE_PATH/AGENTS.md" "$SITE_PATH/AGENTS.override.md"
runtime_generate_instructions

if [ -f "$SITE_PATH/AGENTS.md" ] && [ -f "$SITE_PATH/AGENTS.override.md" ] && grep -q "WP-CLI: \`wp\`" "$SITE_PATH/AGENTS.md" && grep -q "WP_CODING_AGENTS_CODEX_MEMORY_START" "$SITE_PATH/AGENTS.override.md"; then
  pass "AGENTS.md fallback template generated for Codex"
else
  fail "AGENTS.md fallback template generated for Codex"
fi

if [ ! -e "$SITE_PATH/CLAUDE.md" ]; then
  pass "Codex runtime does not create CLAUDE.md"
else
  fail "Codex runtime does not create CLAUDE.md"
fi

if [ "$(runtime_start_cmd)" = "cd $SITE_PATH && codex" ]; then
  pass "manual start command uses codex"
else
  fail "manual start command uses codex"
fi

_codex_register_runtime_signature
RUNTIME_MU="$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-runtimes.php"
if grep -q "BEGIN runtime:codex" "$RUNTIME_MU" && grep -q "CODEX_THREAD_ID" "$RUNTIME_MU"; then
  pass "Codex runtime signature registered"
else
  fail "Codex runtime signature registered"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "OK: codex runtime"
else
  echo "FAILED: codex runtime"
  exit 1
fi
