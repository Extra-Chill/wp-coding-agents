#!/bin/bash
# dm-agent-sync.sh — Claude Code SessionStart hook
#
# Runs before every Claude Code session. Queries Data Machine for all active
# agents and their files, then updates CLAUDE.md with current @ includes.
# New agents created after setup are automatically discovered.
#
# Installed to: $SITE_PATH/.claude/hooks/dm-agent-sync.sh
# Triggered by: Claude Code SessionStart hook

set -euo pipefail

SITE_PATH="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$SITE_PATH" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Detect WP-CLI command
# ---------------------------------------------------------------------------

detect_wp_cmd() {
  # 1. Installed Studio CLI
  if [ -f "$SITE_PATH/STUDIO.md" ] && command -v studio &>/dev/null; then
    echo "studio wp"
    return
  fi

  # 2. Dev CLI — site lives inside the Studio repo (developers working on Studio itself)
  if [ -f "$SITE_PATH/STUDIO.md" ]; then
    local search_dir="$SITE_PATH"
    while [ "$search_dir" != "/" ]; do
      local dev_cli="$search_dir/apps/cli/dist/cli/main.mjs"
      if [ -f "$dev_cli" ]; then
        echo "node $dev_cli wp"
        return
      fi
      search_dir=$(dirname "$search_dir")
    done
  fi

  # 3. System wp-cli
  if command -v wp &>/dev/null; then
    local cmd="wp --path=$SITE_PATH"
    if [ "$(id -u)" -eq 0 ]; then
      cmd="$cmd --allow-root"
    fi
    echo "$cmd"
    return
  fi

  return 1
}

WP_CMD=$(detect_wp_cmd) || exit 0

# ---------------------------------------------------------------------------
# Refresh composable files before computing @ includes
# ---------------------------------------------------------------------------
# SectionRegistry callbacks can read live state (Intelligence sources, skill
# inventory, etc.). DM regenerates composable files when their feeder state
# fires a registered invalidation hook, but those hooks only run inside a
# WordPress request. State changed via direct DB edits, cron, or external
# processes would leave the on-disk file stale. Running `agent compose` here
# guarantees AGENTS.md (and any sibling composable files) match live state
# at the moment the coding-agent session starts.

$WP_CMD datamachine memory compose >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Query active agents from Data Machine
# ---------------------------------------------------------------------------

AGENTS_RAW=$($WP_CMD datamachine agents list --format=json 2>/dev/null) || exit 0

# Extract JSON array. WP-CLI may append summary text (e.g. "Total: 2 agent(s).")
# on the same line as the closing bracket. Use Python to safely extract the array.
ACTIVE_SLUGS=$(echo "$AGENTS_RAW" | python3 -c "
import sys, json, re
raw = sys.stdin.read()
# Extract the JSON array — everything from first [ to its matching ]
match = re.search(r'\[.*\]', raw, re.DOTALL)
if not match:
    sys.exit(0)
data = json.loads(match.group())
for a in data:
    # Treat empty/missing status as active. Data Machine removed the status
    # field as 'dead weight' (Extra-Chill/data-machine 1826756c); 'agents list'
    # now returns status='' for every row. Filtering strictly on 'active'
    # excludes everything and silently empties CLAUDE.md.
    status = a.get('status') or 'active'
    if status == 'active':
        print(a['agent_slug'])
" 2>/dev/null) || exit 0

if [ -z "$ACTIVE_SLUGS" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Collect files from all active agents, deduplicating shared files
# ---------------------------------------------------------------------------

ALL_FILES=""
while IFS= read -r slug; do
  PATHS_RAW=$($WP_CMD datamachine memory paths --agent="$slug" --format=json 2>/dev/null) || continue

  FILES=$(echo "$PATHS_RAW" | python3 -c "
import sys, json, re
raw = sys.stdin.read()
match = re.search(r'\{.*\}', raw, re.DOTALL)
if not match:
    sys.exit(0)
data = json.loads(match.group())
for f in data.get('relative_files', []):
    print(f)
" 2>/dev/null) || continue

  if [ -n "$FILES" ]; then
    ALL_FILES="${ALL_FILES}${ALL_FILES:+
}${FILES}"
  fi
done <<< "$ACTIVE_SLUGS"

if [ -z "$ALL_FILES" ]; then
  exit 0
fi

# Deduplicate while preserving order
UNIQUE_FILES=$(echo "$ALL_FILES" | awk '!seen[$0]++')

# Build @ includes block
AT_INCLUDES=""
while IFS= read -r f; do
  AT_INCLUDES="${AT_INCLUDES}@${f}
"
done <<< "$UNIQUE_FILES"

DISCOVER_LINE="Discover DM paths: \`$WP_CMD datamachine memory paths\`"
NEW_CONTENT="${AT_INCLUDES}
${DISCOVER_LINE}"

# ---------------------------------------------------------------------------
# Update CLAUDE.md between sentinels
# ---------------------------------------------------------------------------

CLAUDE_MD_PATH="$SITE_PATH/CLAUDE.md"

if [ ! -f "$CLAUDE_MD_PATH" ]; then
  # No CLAUDE.md — create minimal version with sentinels
  cat > "$CLAUDE_MD_PATH" << MINEOF
# $(basename "$SITE_PATH")

## Data Machine Memory

<!-- DM_AGENT_SYNC_START -->
${NEW_CONTENT}
<!-- DM_AGENT_SYNC_END -->

## Memory Protocol

Update MEMORY.md when you learn something persistent — read it first, append.
MINEOF
  exit 0
fi

EXISTING=$(cat "$CLAUDE_MD_PATH")

# Try sentinel-based replacement first
if echo "$EXISTING" | grep -q '<!-- DM_AGENT_SYNC_START -->'; then
  python3 -c "
import sys

content = sys.stdin.read()
new_block = sys.argv[1]
start_sentinel = '<!-- DM_AGENT_SYNC_START -->'
end_sentinel = '<!-- DM_AGENT_SYNC_END -->'

start_idx = content.index(start_sentinel) + len(start_sentinel)
end_idx = content.index(end_sentinel)

updated = content[:start_idx] + '\n' + new_block + '\n' + content[end_idx:]
sys.stdout.write(updated)
" "$NEW_CONTENT" <<< "$EXISTING" > "$CLAUDE_MD_PATH"
  exit 0
fi

# Fallback: heading-based replacement for pre-upgrade CLAUDE.md files
if echo "$EXISTING" | grep -q '## Data Machine Memory'; then
  python3 -c "
import sys, re

content = sys.stdin.read()
new_block = sys.argv[1]

pattern = r'(## Data Machine Memory\n).*?(?=\n## |\Z)'
replacement = r'\g<1>\n<!-- DM_AGENT_SYNC_START -->\n' + new_block.replace('\\\\', '\\\\\\\\') + r'\n<!-- DM_AGENT_SYNC_END -->'
updated = re.sub(pattern, replacement, content, count=1, flags=re.DOTALL)
sys.stdout.write(updated)
" "$NEW_CONTENT" <<< "$EXISTING" > "$CLAUDE_MD_PATH"
  exit 0
fi

# No heading found — append DM section
cat >> "$CLAUDE_MD_PATH" << APPENDEOF

## Data Machine Memory

<!-- DM_AGENT_SYNC_START -->
${NEW_CONTENT}
<!-- DM_AGENT_SYNC_END -->
APPENDEOF
