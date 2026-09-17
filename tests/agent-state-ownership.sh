#!/bin/bash
# tests/agent-state-ownership.sh — agent state follows the service identity (#598).
#
# A root-run setup for a non-root service must not leave agent-maintained state
# root-owned, and a non-root upgrade that finds such state must report it ONCE
# with the repair command rather than failing file by file in every later
# phase. What must hold:
#
#   1. The roots are exactly the agent-maintained ones. Privileged host state
#      (units, sudoers, journald) never appears; symlinked roots are skipped.
#   2. The audit is read-only, reports each unmaintainable root once, names
#      the owner, emits a single machine-readable root_repair_required record,
#      and marks descendants as not maintainable so phases can skip cleanly.
#   3. A fully owned tree audits clean and reconciles to a no-op.
#   4. Reconcile (root) pairs the site group with roots under the site and the
#      service user's group elsewhere, and never touches a symlinked root.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source lib/common.sh
source lib/grants.sh
# shellcheck disable=SC1091
source lib/agent-state-ownership.sh

FAILED=0
ok() { echo "  ok   $1"; }
fail() { echo "  FAIL $1" >&2; FAILED=1; }

SITE_PATH="$TMP/site"
mkdir -p "$SITE_PATH/.opencode/skills" "$SITE_PATH/.claude/hooks" "$SITE_PATH/.wp-coding-agents" "$TMP/kimaki-config/plugins"
printf 'x\n' > "$SITE_PATH/.wp-coding-agents/installation-profile"
printf 'x\n' > "$TMP/kimaki-config/plugins/dm-agent-sync.ts"
ln -s "$TMP/elsewhere" "$SITE_PATH/.codex"
RESOLVED_KIMAKI_CONFIG_DIR="$TMP/kimaki-config"
LOCAL_MODE=false
SERVICE_USER="$(id -un)"
UPDATED_ITEMS=()

echo "1. roots are the agent-maintained set"
roots="$(agent_state_ownership_roots | sort)"
want="$(printf '%s\n' "$SITE_PATH/.claude" "$SITE_PATH/.opencode" "$SITE_PATH/.wp-coding-agents" "$TMP/kimaki-config" | sort)"
if [ "$roots" = "$want" ]; then ok "exact root set, symlinked .codex skipped"; else fail "roots: $roots"; fi
case "$roots" in
  *systemd*|*sudoers*|*journald*) fail "privileged host state leaked into agent roots" ;;
  *) ok "no privileged host state" ;;
esac

echo "2. a fully owned tree audits clean"
agent_state_ownership_audit >"$TMP/audit.out" 2>&1
[ "$AGENT_STATE_OWNERSHIP_ROOT_REPAIR_REQUIRED" = false ] && ok "no repair required" || fail "clean tree flagged: $(<"$TMP/audit.out")"
agent_state_ownership_can_maintain "$SITE_PATH/.opencode/skills/x" && ok "descendants maintainable" || fail "clean descendant marked unmaintainable"

if [ "$(id -u)" -ne 0 ]; then
  echo "3. unmaintainable roots report once, with owner and repair command"
  # A root-run setup leaves files owned by another uid. Group-writable is not
  # maintainable (only the owner can chmod), so ownership alone decides.
  # Non-root cannot fabricate a foreign owner, so pin the identity the audit
  # compares against to a uid that is not ours for one root.
  chmod 555 "$TMP/kimaki-config/plugins"
  AGENT_STATE_OWNERSHIP_UID=0
  audit_out="$(agent_state_ownership_audit 2>&1)"
  case "$audit_out" in
    *"root-owned agent state found"*"$TMP/kimaki-config"*"one-time repair: sudo "*"--reconcile-agent-state-ownership"*) ok "one consolidated warning with repair command" ;;
    *) fail "audit output: $audit_out" ;;
  esac
  case "$audit_out" in
    *'"status":"root_repair_required","component":"agent_state_ownership","paths":["'*'"],"repair_command":"'*) ok "single machine-readable record" ;;
    *) fail "no root_repair_required record: $audit_out" ;;
  esac
  case "$audit_out" in
    *"(owner: $(id -un))"*) ok "owner named" ;;
    *) fail "owner not named: $audit_out" ;;
  esac
  # Re-run in-process so the state arrays are populated for the maintainability check.
  agent_state_ownership_audit >/dev/null 2>&1
  unset AGENT_STATE_OWNERSHIP_UID
  ! agent_state_ownership_can_maintain "$TMP/kimaki-config/plugins/dm-agent-sync.ts" && ok "descendant of unmaintainable root is skipped" || fail "descendant still reported maintainable"
  [ "$(printf '%s\n' "$audit_out" | grep -c 'root_repair_required')" -eq 1 ] && ok "exactly one record for all roots" || fail "record emitted per root"
  [ "$(file_mode "$TMP/kimaki-config/plugins")" = 555 ] && ok "audit did not mutate" || fail "audit mutated permissions"
  chmod 755 "$TMP/kimaki-config/plugins"

  echo "4. reconcile is a no-op without root"
  agent_state_ownership_reconcile >"$TMP/rec.out" 2>&1
  [ "${AGENT_STATE_OWNERSHIP_CHANGED:-0}" -eq 0 ] && [ "${#UPDATED_ITEMS[@]}" -eq 0 ] && ok "no changes, no summary item" || fail "non-root reconcile acted: $(<"$TMP/rec.out")"
else
  echo "3/4. root: reconcile hands roots to the service user with the right group"
  target="nobody"
  chown -R root:root "$TMP/kimaki-config" "$SITE_PATH"
  chgrp "$(id -gn "$target")" "$SITE_PATH"
  SERVICE_USER="$target" agent_state_ownership_reconcile >"$TMP/rec.out" 2>&1
  [ "$(file_owner "$TMP/kimaki-config/plugins/dm-agent-sync.ts")" = "$target" ] && ok "persistent config reassigned" || fail "kimaki-config still $(file_owner "$TMP/kimaki-config/plugins/dm-agent-sync.ts")"
  [ "$(file_owner "$SITE_PATH/.wp-coding-agents/installation-profile")" = "$target" ] && ok "installation profile reassigned" || fail "profile not reassigned"
  [ "$(file_group "$SITE_PATH/.opencode")" = "$(file_group "$SITE_PATH")" ] && ok "site roots keep the site group" || fail "site group not preserved"
  [ -L "$SITE_PATH/.codex" ] && [ ! -e "$TMP/elsewhere" ] && ok "symlinked root untouched" || fail "symlink followed"
  [ "${AGENT_STATE_OWNERSHIP_CHANGED:-0}" -eq 4 ] && ok "four roots changed" || fail "changed=$AGENT_STATE_OWNERSHIP_CHANGED"
  SERVICE_USER="$target" agent_state_ownership_reconcile >/dev/null 2>&1
  [ "${AGENT_STATE_OWNERSHIP_CHANGED:-0}" -eq 0 ] && ok "second run is a no-op" || fail "not idempotent"
fi

echo "5. upgrade wires the audit, the one-shot flag, and the summary"
grep -qF 'agent_state_ownership_audit' upgrade.sh && ok "upgrade audits as non-root" || fail "upgrade does not audit"
grep -qF -- '--reconcile-agent-state-ownership' upgrade.sh && ok "one-shot repair flag exists" || fail "no one-shot flag"
grep -qF 'AGENT_STATE_OWNERSHIP_ROOT_REPAIR_REQUIRED' upgrade.sh && ok "summary reports root repair" || fail "summary silent"
grep -qF 'agent_state_ownership_reconcile' setup.sh && ok "setup hands state over" || fail "setup does not reconcile"
grep -qF 'agent_state_ownership_reconcile' lib/service-migration.sh && ok "migration hands state over" || fail "migration does not reconcile"
grep -qF 'agent_state_ownership_can_maintain' bridges/kimaki.sh && ok "kimaki config sync skips cleanly" || fail "kimaki sync unguarded"
grep -qF 'agent_state_ownership_can_maintain' lib/opencode-subagents.sh && ok "subagent projection skips cleanly" || fail "projection unguarded"
grep -qF 'agent_state_ownership_can_maintain' runtimes/claude-code.sh && ok "claude hook install skips cleanly" || fail "hook install unguarded"

[ "$FAILED" -eq 0 ] || { echo "FAIL: agent state ownership" >&2; exit 1; }
echo "PASS: agent state follows the service identity"
