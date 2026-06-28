#!/bin/bash
# tests/claude-code-hook-scope.sh — Regression coverage for the Claude Code
# SessionStart hook's agent scoping (hooks/dm-agent-sync.sh).
#
# Two modes:
#   - dm-agent-sync.env present (DM_AGENT_SLUG set) -> inject ONLY that agent's
#     files, exactly like the OpenCode runtime (single configured agent). The
#     `agents list` discovery is skipped entirely.
#   - no sidecar -> discover every active agent and inject all of their files
#     (legacy multi-agent behavior).
#
# We mock `wp` on PATH so the test never touches a real WordPress install and
# the agent list / memory paths are deterministic. STUDIO.md is intentionally
# absent so detect_wp_cmd resolves to `wp --path=...`.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/hooks/dm-agent-sync.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- Mock `wp` --------------------------------------------------------------
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/wp" <<'WPEOF'
#!/bin/bash
# Deterministic Data Machine mock. Recognizes the three calls the hook makes.
args="$*"
case "$args" in
  *"memory compose"*) exit 0 ;;
  *"agents list"*)
    echo '[{"agent_slug":"alpha","agent_name":"Alpha"},{"agent_slug":"beta","agent_name":"Beta"}]'
    echo 'Total: 2 agent(s).'
    ;;
  *"memory paths"*)
    slug=""
    for a in "$@"; do
      case "$a" in --agent=*) slug="${a#--agent=}" ;; esac
    done
    printf '{"agent_slug":"%s","relative_files":["wp-content/uploads/datamachine-files/agents/%s/SOUL.md","wp-content/uploads/datamachine-files/agents/%s/MEMORY.md"]}\n' "$slug" "$slug" "$slug"
    ;;
  *) exit 0 ;;
esac
WPEOF
chmod +x "$BIN/wp"
export PATH="$BIN:$PATH"

FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }

seed_claude_md() {
  local dir="$1"
  cat > "$dir/CLAUDE.md" <<'MDEOF'
# Test Site

## Data Machine Memory

<!-- DM_AGENT_SYNC_START -->
<!-- DM_AGENT_SYNC_END -->
MDEOF
}

# --- Case A: sidecar present -> single-agent scope --------------------------
SITE_A="$TMP/siteA"
mkdir -p "$SITE_A/.claude/hooks"
seed_claude_md "$SITE_A"
cp "$HOOK" "$SITE_A/.claude/hooks/dm-agent-sync.sh"
printf 'DM_AGENT_SLUG=alpha\n' > "$SITE_A/.claude/hooks/dm-agent-sync.env"

CLAUDE_PROJECT_DIR="$SITE_A" bash "$SITE_A/.claude/hooks/dm-agent-sync.sh"

if grep -q 'agents/alpha/SOUL.md' "$SITE_A/CLAUDE.md"; then
  pass "scoped: alpha (configured agent) injected"
else
  fail "scoped: alpha (configured agent) injected"
fi
if grep -q 'agents/beta/' "$SITE_A/CLAUDE.md"; then
  fail "scoped: beta (other agent) excluded"
else
  pass "scoped: beta (other agent) excluded"
fi

# --- Case B: no sidecar -> all active agents -------------------------------
SITE_B="$TMP/siteB"
mkdir -p "$SITE_B/.claude/hooks"
seed_claude_md "$SITE_B"
cp "$HOOK" "$SITE_B/.claude/hooks/dm-agent-sync.sh"

CLAUDE_PROJECT_DIR="$SITE_B" bash "$SITE_B/.claude/hooks/dm-agent-sync.sh"

if grep -q 'agents/alpha/SOUL.md' "$SITE_B/CLAUDE.md" && grep -q 'agents/beta/SOUL.md' "$SITE_B/CLAUDE.md"; then
  pass "unscoped: all active agents injected (alpha + beta)"
else
  fail "unscoped: all active agents injected (alpha + beta)"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "OK — claude-code hook scope"
else
  echo "FAILED — claude-code hook scope"
  exit 1
fi
