#!/bin/bash
# tests/opencode-claude-auth-refresh-hardening.sh - guard Claude OAuth refresh hardening.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$SCRIPT_DIR/runtimes/opencode/plugins/claude-code-auth.ts"

require_source() {
  local pattern="$1"
  local description="$2"
  if ! grep -Fq "$pattern" "$PLUGIN"; then
    echo "FAIL: missing $description" >&2
    echo "pattern: $pattern" >&2
    exit 1
  fi
}

require_source "function refreshLockPath()" "shared refresh lock path"
require_source "async function withRefreshLock" "cross-process refresh lock"
require_source "await readAnthropicAuth()" "auth file re-read inside refresh path"
require_source "if (usableAccessToken(latest)) return latest" "winner-token reuse after lock acquisition"
require_source "function isInvalidGrantFailure" "invalid_grant refresh failure classifier"
require_source "const candidates = dedupeOAuthCandidates([latest, oauth, active, ...store.accounts])" "remembered account retry candidates"
require_source "summarizeRefreshFailures" "redacted refresh failure diagnostics"
require_source "getFreshOAuthOrRotate" "request path refresh fallback wrapper"

echo "PASS: tests/opencode-claude-auth-refresh-hardening.sh"
