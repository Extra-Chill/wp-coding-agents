#!/usr/bin/env bash
# tests/cli-channel-binary-path.sh — Regression coverage for issue #198.
#
# The command registered for the kimaki CLI channel is shelled by the Data
# Machine Code CLI transport from `agents/dispatch-message`, which runs inside
# PHP-FPM as the WordPress web user (www-data) on WP-cron / Action Scheduler
# fires. That user is NOT the kimaki.service user.
#
# On a RUN_AS_ROOT install the kimaki binary resolves under /root/.kimaki/bin
# (and the data dir under /root, mode 0700). www-data cannot traverse 0700
# /root, so proc_open fails with EACCES and every scheduled dispatch dies as
# `datamachine_code_cli_dispatch_spawn_failed`. The opencode service-user home
# (/home/opencode, mode 0750) is the same trap.
#
# The resolver (_kimaki_find_native_binary) and the KIMAKI_BIN short-circuit in
# _kimaki_register_cli_channel must therefore only register a binary whose
# ancestor directories are world-traversable (`o+x`), preferring a reachable
# system-prefix path over any private-home wrapper.
#
# Asserts:
#   1. _kimaki_path_is_web_traversable accepts a 0755-ancestor path and
#      rejects a 0700- and a 0750-ancestor path (the /root and /home/opencode
#      traps).
#   2. _kimaki_find_native_binary skips an executable-but-unreachable PATH
#      entry (private-home wrapper) in favor of a later reachable one.
#   3. _kimaki_register_cli_channel ignores a KIMAKI_BIN that is executable but
#      trapped under a non-traversable home, falling back to the reachable
#      PATH binary.
#   4. The registered command is never a path under a non-traversable home.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

# mktemp -d creates the dir at 0700 by design. This test simulates a WEB-
# REACHABLE install prefix, so make the temp root world-traversable; the
# individual "trap" dirs below re-tighten their own permissions to 0700/0750.
# (/tmp itself is 1777, and the temp root's parent chain is world-traversable
# in CI, so this gives us a clean 0755 base to build reachable paths under.)
chmod 0755 "$TMP"

# Silence helper logs; capture cli_channel_register args for assertions.
log() { :; }
warn() { printf 'WARN: %s\n' "$1" >&2; }
cli_channel_register() {
  printf '%s\0' "$@" > "$TMP/cli-channel.args"
}

DRY_RUN=false
UPDATED_ITEMS=()

# shellcheck disable=SC1091
source "$ROOT/bridges/kimaki.sh"

FAILED=0
fail() { echo "  FAIL $1"; FAILED=$((FAILED + 1)); }
ok()   { echo "  ok   $1"; }

# A fake kimaki binary the resolver can find.
make_kimaki() {
  local dir="$1"
  mkdir -p "$dir"
  printf '#!/bin/sh\nexit 0\n' > "$dir/kimaki"
  chmod 0755 "$dir/kimaki"
}

# Read the command (2nd arg) that _kimaki_register_cli_channel passed through.
registered_command() {
  python3 - "$TMP/cli-channel.args" <<'PY'
import sys
with open(sys.argv[1], 'rb') as handle:
    parts = [p.decode() for p in handle.read().split(b'\0') if p]
# cli_channel_register "kimaki" "<command>" "<args_json>" "<detach>" "<timeout>"
print(parts[1] if len(parts) > 1 else '')
PY
}

# --- 1. _kimaki_path_is_web_traversable on hostile vs friendly ancestors ----
echo "==> _kimaki_path_is_web_traversable ancestor checks"

reachable_dir="$TMP/reachable/bin"        # all ancestors 0755 by default
make_kimaki "$reachable_dir"
if _kimaki_path_is_web_traversable "$reachable_dir/kimaki"; then
  ok "accepts 0755-ancestor path"
else
  fail "should accept 0755-ancestor path"
fi

# Simulate /root (0700) trap.
root_trap="$TMP/roothome"                 # stands in for /root
mkdir -p "$root_trap/.kimaki/bin"
make_kimaki "$root_trap/.kimaki/bin"
chmod 0700 "$root_trap"
if _kimaki_path_is_web_traversable "$root_trap/.kimaki/bin/kimaki"; then
  fail "should REJECT 0700-ancestor (/root) path"
else
  ok "rejects 0700-ancestor (/root) path"
fi

# Simulate /home/opencode (0750) trap.
home_trap="$TMP/opencodehome"             # stands in for /home/opencode
mkdir -p "$home_trap/.kimaki/bin"
make_kimaki "$home_trap/.kimaki/bin"
chmod 0750 "$home_trap"
if _kimaki_path_is_web_traversable "$home_trap/.kimaki/bin/kimaki"; then
  fail "should REJECT 0750-ancestor (/home/opencode) path"
else
  ok "rejects 0750-ancestor (/home/opencode) path"
fi

# --- 2. resolver skips unreachable PATH entry for a reachable one -----------
echo "==> _kimaki_find_native_binary prefers reachable PATH entry"

# PATH puts the 0700-trapped wrapper FIRST (mirrors root's $PATH ordering),
# then a reachable system-style dir.
unset KIMAKI_BIN || true
resolved="$(PATH="$root_trap/.kimaki/bin:$reachable_dir:/usr/bin:/bin" _kimaki_find_native_binary)"
if [ "$resolved" = "$reachable_dir/kimaki" ]; then
  ok "skips 0700 wrapper, returns reachable binary"
else
  fail "expected $reachable_dir/kimaki, got '$resolved'"
fi

# --- 3. register ignores trapped KIMAKI_BIN, falls back to reachable PATH ----
echo "==> _kimaki_register_cli_channel ignores trapped KIMAKI_BIN"

rm -f "$TMP/cli-channel.args"
KIMAKI_BIN="$root_trap/.kimaki/bin/kimaki"   # executable but trapped under 0700
PATH="$reachable_dir:/usr/bin:/bin" _kimaki_register_cli_channel
got="$(registered_command)"
if [ "$got" = "$reachable_dir/kimaki" ]; then
  ok "trapped KIMAKI_BIN ignored; registered reachable $got"
else
  fail "expected reachable $reachable_dir/kimaki, got '$got'"
fi

# --- 4. registered command is never under a non-traversable home ------------
echo "==> registered command is web-traversable"

if _kimaki_path_is_web_traversable "$got"; then
  ok "registered command '$got' is web-traversable"
else
  fail "registered command '$got' is NOT web-traversable"
fi

# Sanity: a reachable KIMAKI_BIN is still honored (no regression).
rm -f "$TMP/cli-channel.args"
reachable_bin_dir="$TMP/reachable2/bin"
make_kimaki "$reachable_bin_dir"
KIMAKI_BIN="$reachable_bin_dir/kimaki"
PATH="/usr/bin:/bin" _kimaki_register_cli_channel
got2="$(registered_command)"
if [ "$got2" = "$reachable_bin_dir/kimaki" ]; then
  ok "reachable KIMAKI_BIN still honored (no regression)"
else
  fail "expected $reachable_bin_dir/kimaki, got '$got2'"
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi
echo "OK: all cli-channel binary-path assertions passed"
