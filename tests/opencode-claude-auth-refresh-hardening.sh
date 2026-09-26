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

refuse_source() {
  local pattern="$1"
  local description="$2"
  if grep -Fq "$pattern" "$PLUGIN"; then
    echo "FAIL: found forbidden $description" >&2
    echo "pattern: $pattern" >&2
    exit 1
  fi
}

require_source "function authStateLockPath()" "shared Kimaki-compatible auth-state lock path"
require_source 'authFilePath()}.lock' "lock directory shared with Kimaki's withAuthStateLock"
require_source "AUTH_LOCK_STALE_MS = 30_000" "30s stale window matching Kimaki's lock contract"
require_source "async function withAuthStateLock" "cross-process shared auth-state lock"
refuse_source "anthropic-refresh.lock" "private lock file that races Kimaki's lock (#626)"
require_source "if (process.env.KIMAKI) return {};" "Kimaki sessions register no auth hook (#626)"
require_source "const isRemote = Boolean(process.env.WP_CODING_AGENTS_REMOTE_AUTH)" "remote pasted-code login flow"
require_source "await readAnthropicAuth()" "auth file re-read inside refresh path"
require_source "if (usableAccessToken(latest)) return latest" "winner-token reuse after lock acquisition"
require_source "function isInvalidGrantFailure" "invalid_grant refresh failure classifier"
require_source "const candidates = dedupeOAuthCandidates([latest, oauth, active, ...store.accounts])" "remembered account retry candidates"
require_source "summarizeRefreshFailures" "redacted refresh failure diagnostics"
require_source "getFreshOAuthOrRotate" "request path refresh fallback wrapper"
require_source "function replaceAccount" "rotated refresh token replaces stale account entry"
require_source "replaceAccount(store, candidate, refreshed)" "normal refresh replaces stale account entry"
require_source "async function setAnthropicAuth" "auth file and live OpenCode auth sync helper"
require_source "client?.auth?.set?.({ providerID: \"anthropic\", auth })" "live OpenCode auth state sync after credential changes"
require_source "async function refreshOAuthAfterAuthFailure" "auth failure refresh retry helper"
require_source "function isRateLimitFailure" "rate-limit classifier keeps 429 from spending a refresh token"
require_source "function isAuthenticationFailure" "authentication failure classifier allows refresh-first retry"
require_source "account.accountId === identity.accountId" "identity-based account matching"
require_source "identity?.email || existing?.email" "identity preservation on account upsert"
require_source "async function rotateAnthropicAccount" "pool rotation helper"
require_source "usableAccessToken(candidate)" "rotation reuses a still-valid access token"
require_source "rotateAnthropicAccount(currentAuth, client)" "rate-limit retry rotates to the next pooled account"
require_source "tried.has(rotated.refresh)" "rotation stops when every account has been tried"

node "$SCRIPT_DIR/tests/claude-client-identity.mjs"
node "$SCRIPT_DIR/tests/opencode-claude-auth-kimaki-coexistence.mjs"

echo "PASS: tests/opencode-claude-auth-refresh-hardening.sh"
