#!/bin/bash
# tests/self-upgrade.sh — the agent can upgrade its own install, and only that.
#
# Installer: the root-owned command, its config, and a sudoers grant limited to
# `start` and `status` are installed only on a managed VPS with a non-root
# service user and a locked-down checkout. Wrapper: rejects every argument
# shape it does not own, and refuses to run privileged steps without root.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
PASS=0
check() {
  if [ "$1" -eq 0 ]; then echo "  ok   $2"; PASS=$((PASS + 1)); else echo "  FAIL $2"; FAIL=$((FAIL + 1)); fi
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/grants.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/self-upgrade.sh"

log() { :; }
warn() { printf '%s\n' "$*" >> "$TMP/warn.log"; }
chown() { :; }            # the test is not root; ownership is stubbed below
DRY_RUN=false
LOCAL_MODE=false
EXTERNAL_WORDPRESS=false
SERVICE_USER=pi
SITE_PATH=/var/www/site
GRANTS_SUDOERS_DIR="$TMP/sudoers.d"
SELF_UPGRADE_BIN="$TMP/sbin/wp-coding-agents-upgrade"
SELF_UPGRADE_CONFIG="$TMP/etc/self-upgrade.conf"
export WP_CODING_AGENTS_TEST_EUID=0
OWNER=root
file_owner() { printf '%s\n' "$OWNER"; }
file_mode() { printf '755\n'; }
mkdir -p "$TMP/checkout/.git"
SCRIPT_DIR_REAL="$SCRIPT_DIR"
reset() { rm -rf "$TMP/sbin" "$TMP/etc" "$TMP/sudoers.d" "$TMP/warn.log"; }

run_apply() { ( SCRIPT_DIR="$1"; self_upgrade_apply ); }

echo "==> installs on a managed VPS with a locked checkout"
# The installer reads the wrapper from SCRIPT_DIR/scripts, so point at the repo
# but stub the lock check's ownership view (the repo is not root-owned here).
run_apply "$SCRIPT_DIR_REAL"
cmp -s "$SCRIPT_DIR_REAL/scripts/wp-coding-agents-upgrade" "$SELF_UPGRADE_BIN"; check $? "wrapper installed verbatim"
[ "$(stat -c %a "$SELF_UPGRADE_BIN" 2>/dev/null || stat -f %Lp "$SELF_UPGRADE_BIN")" = 755 ]; check $? "wrapper is 0755"
[ "$(cat "$SELF_UPGRADE_CONFIG")" = "$(printf 'CHECKOUT=%s\nSITE_PATH=/var/www/site\nTRUST_REF=main' "$SCRIPT_DIR_REAL")" ]; check $? "config names checkout, site, and trust ref main"
GRANT="$GRANTS_SUDOERS_DIR/wp-coding-agents-self-upgrade"
[ "$(cat "$GRANT")" = "pi ALL=(root) NOPASSWD: $SELF_UPGRADE_BIN start, $SELF_UPGRADE_BIN status" ]; check $? "grant allows exactly start and status"
[ "$(stat -c %a "$GRANT" 2>/dev/null || stat -f %Lp "$GRANT")" = 440 ]; check $? "grant is 0440"
grep -q "apply\|\*" "$GRANT"; [ $? -ne 0 ]; check $? "grant has no wildcard and no apply"
if command -v visudo >/dev/null 2>&1; then
  visudo -cf "$GRANT" >/dev/null 2>&1; check $? "grant passes visudo"
fi

echo "==> refuses when the checkout is not locked down"
reset; OWNER=pi
run_apply "$SCRIPT_DIR_REAL"
[ ! -e "$SELF_UPGRADE_BIN" ] && [ ! -e "$GRANTS_SUDOERS_DIR" ]; check $? "nothing installed for an agent-writable checkout"
grep -q "root-owned git checkout" "$TMP/warn.log"; check $? "operator told why"
OWNER=root

echo "==> scope"
reset; ( LOCAL_MODE=true; run_apply "$SCRIPT_DIR_REAL" ); [ ! -e "$SELF_UPGRADE_BIN" ]; check $? "local installs: nothing"
reset; ( SERVICE_USER=root; run_apply "$SCRIPT_DIR_REAL" ); [ ! -e "$SELF_UPGRADE_BIN" ]; check $? "root service user: no grant needed"
reset; ( EXTERNAL_WORDPRESS=true; run_apply "$SCRIPT_DIR_REAL" ); [ ! -e "$SELF_UPGRADE_BIN" ]; check $? "external WordPress: nothing"
reset; ( WP_CODING_AGENTS_TEST_EUID=1000; run_apply "$SCRIPT_DIR_REAL" ); [ ! -e "$SELF_UPGRADE_BIN" ]; check $? "non-root run: nothing"
reset; mkdir -p "$TMP/etc"; printf 'SITE_PATH=/var/www/other\n' > "$SELF_UPGRADE_CONFIG"
run_apply "$SCRIPT_DIR_REAL"
grep -q "other" "$SELF_UPGRADE_CONFIG" && [ ! -e "$SELF_UPGRADE_BIN" ]; check $? "a second site does not take over the first site's config"

echo "==> host config keys persist across upgrades (#799)"
reset
( HOST_CONFIG_REPO=ssh://git@example.invalid/host-config.git HOST_CONFIG_PATH=hosts/agent1.conf HOST_CONFIG_REF=main
  run_apply "$SCRIPT_DIR_REAL" )
grep -qx 'HOST_CONFIG_REPO=ssh://git@example.invalid/host-config.git' "$SELF_UPGRADE_CONFIG"; check $? "host config repo recorded"
grep -qx 'HOST_CONFIG_PATH=hosts/agent1.conf' "$SELF_UPGRADE_CONFIG"; check $? "host config path recorded"
grep -qx 'HOST_CONFIG_REF=main' "$SELF_UPGRADE_CONFIG"; check $? "host config ref recorded"
run_apply "$SCRIPT_DIR_REAL"   # a later upgrade without the flags
grep -qx 'HOST_CONFIG_REPO=ssh://git@example.invalid/host-config.git' "$SELF_UPGRADE_CONFIG" \
  && grep -qx 'HOST_CONFIG_PATH=hosts/agent1.conf' "$SELF_UPGRADE_CONFIG" \
  && grep -qx 'HOST_CONFIG_REF=main' "$SELF_UPGRADE_CONFIG"; check $? "host config keys preserved on a flagless upgrade"
grep -qx "SITE_PATH=/var/www/site" "$SELF_UPGRADE_CONFIG"; check $? "site path still recorded alongside host config"
GRANT="$GRANTS_SUDOERS_DIR/wp-coding-agents-self-upgrade"
[ "$(cat "$GRANT")" = "pi ALL=(root) NOPASSWD: $SELF_UPGRADE_BIN start, $SELF_UPGRADE_BIN status" ]; check $? "grant is unchanged by host config (still exactly start and status)"
reset
run_apply "$SCRIPT_DIR_REAL"
[ "$(cat "$SELF_UPGRADE_CONFIG")" = "$(printf 'CHECKOUT=%s\nSITE_PATH=/var/www/site\nTRUST_REF=main' "$SCRIPT_DIR_REAL")" ]; check $? "no host config keys appear without the flags"

echo "==> wrapper argument and privilege surface"
W="$SCRIPT_DIR_REAL/scripts/wp-coding-agents-upgrade"
bash -n "$W"; check $? "wrapper parses"
for args in "" "frobnicate" "start now" "status --all" "apply x"; do
  # shellcheck disable=SC2086
  bash "$W" $args >/dev/null 2>&1; [ $? -eq 2 ]; check $? "rejects '${args}'"
done
if [ "$(id -u)" -ne 0 ]; then
  bash "$W" start 2>&1 | grep -q "must run as root"; check $? "start refuses without root"
  bash "$W" apply 2>&1 | grep -q "must run as root"; check $? "apply refuses without root"
  bash "$W" status | head -1 | grep -qx "idle\|running"; check $? "status works unprivileged"
fi
grep -q 'grep -q "/$UNIT.service\\$" /proc/self/cgroup' "$W"; check $? "apply only runs inside its own transient unit"
grep -q 'checkout --quiet --force --detach "origin/$TRUST_REF"' "$W"; check $? "runs only the fetched trust ref"

echo "==> installer tools use locked local prefixes, not the caller PATH"
eval "$(sed -n '/^installer_path() {/,/^}/p' "$W")"
root_locked() { [ "${DENIED_PREFIX:-}" != "$1" ]; }
die() { printf '%s\n' "$1" >&2; exit "$2"; }
BOOTSTRAP_PATH=/usr/sbin:/usr/bin:/sbin:/bin
CHILD_PATH="$(PATH="$BOOTSTRAP_PATH" installer_path)"
[ "$CHILD_PATH" = "/usr/local/sbin:/usr/local/bin:$BOOTSTRAP_PATH" ]; check $? "installer receives setup's local prefixes with the fixed bootstrap tail"
env PATH="$CHILD_PATH" sh -c 'command -v sh >/dev/null'; check $? "installer child can resolve tools through the admitted PATH"
if [ -d /usr/local/bin ]; then
  ( DENIED_PREFIX=/usr/local/bin; PATH="$BOOTSTRAP_PATH" installer_path ) >"$TMP/path.out" 2>&1
  [ $? -eq 2 ]; check $? "an unlocked executable prefix is refused before the installer starts"
fi
if [ -d /usr/local ]; then
  ( DENIED_PREFIX=/usr/local; PATH="$BOOTSTRAP_PATH" installer_path ) >"$TMP/path.out" 2>&1
  [ $? -eq 2 ]; check $? "an unlocked parent of executable prefixes is refused"
fi

echo "==> host-declared opt-ins come from the mirror's merged ref (#799)"
# Hermetic: a local bare repo is HOST_CONFIG_REPO, the mirror lives in TMP,
# and the wrapper's host_config_* functions are driven directly with die,
# record, and root_locked stubbed.
eval "$(sed -n '/^host_config_fetch() {/,/^}/p' "$W")"
eval "$(sed -n '/^host_config_read() {/,/^}/p' "$W")"
eval "$(sed -n '/^host_config_parse() {/,/^}/p' "$W")"
eval "$(sed -n '/^host_config_collect_flags() {/,/^}/p' "$W")"
log() { :; }
record() { printf '%s\n' "$1" > "$TMP/record"; }
die() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }
root_locked() { return 0; }
export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
GIT="git -c user.email=t@test -c user.name=t"
HSRC="$TMP/host-src"
mkdir -p "$HSRC/hosts"
git init -q -b main "$HSRC" 2>/dev/null || { git init -q "$HSRC"; git -C "$HSRC" checkout -q -b main; }
printf '# reviewed opt-ins\nWORDPRESS_CHAT_AGENT=intelligence\n' > "$HSRC/hosts/agent1.conf"
$GIT -C "$HSRC" add -A && $GIT -C "$HSRC" commit -qm 'opt in'
git clone -q --bare "$HSRC" "$TMP/host-config-origin.git"
HOST_CONFIG_REPO="$TMP/host-config-origin.git"
HOST_CONFIG_PATH=hosts/agent1.conf
HOST_CONFIG_REF=main
HOST_CONFIG_MIRROR="$TMP/var/host-config.git"

# Collect in a subshell (die exits it) and print the flags it produced.
collect() { ( host_config_collect_flags >/dev/null 2>&1 && printf '%s\n' "${HOST_CONFIG_FLAGS[@]}" ); }

[ "$(collect)" = "$(printf -- '--wordpress-chat-agent\nintelligence')" ]; check $? "a valid host config adds --wordpress-chat-agent <slug>"
[ -d "$HOST_CONFIG_MIRROR" ] && [ ! -e "$HOST_CONFIG_MIRROR/hosts/agent1.conf" ]; check $? "mirror is bare: no working tree to edit"

# The trust anchor is the merged remote ref. Edits to a checkout — even
# committed ones that were never pushed — have no effect on what is read.
printf 'WORDPRESS_CHAT_AGENT=attacker\n' > "$HSRC/hosts/agent1.conf"
[ "$(collect)" = "$(printf -- '--wordpress-chat-agent\nintelligence')" ]; check $? "an edited checkout has no effect (uncommitted)"
$GIT -C "$HSRC" commit -qam 'local only'
[ "$(collect)" = "$(printf -- '--wordpress-chat-agent\nintelligence')" ]; check $? "a committed-but-unpushed change has no effect"

push_content() { printf '%s\n' "$1" > "$HSRC/hosts/agent1.conf"; $GIT -C "$HSRC" commit -qam update; git -C "$HSRC" push -q "$HOST_CONFIG_REPO" main; }

# Fail closed: unknown keys, bad slugs, metacharacters, malformed lines.
refused() { rm -f "$TMP/record"; ( host_config_collect_flags ) >/dev/null 2>&1 && return 1; grep -qx host-config-invalid "$TMP/record"; }
push_content 'EVIL_KEY=1'
refused; check $? "an unknown key fails closed (recorded host-config-invalid)"
push_content 'WORDPRESS_CHAT_AGENT=Bad_Slug'
refused; check $? "an uppercase slug fails closed"
push_content 'WORDPRESS_CHAT_AGENT=a;rm -rf /'
refused; check $? "shell metacharacters in the value fail closed"
push_content 'not a key value line'
refused; check $? "a malformed line fails closed"
push_content 'WORDPRESS_CHAT_AGENT=$(reboot)'
refused; check $? "a command substitution in the value fails closed"

# Removing the key must remove its effect: the absent key disables.
push_content '# opt-in removed'
[ "$(collect)" = "--no-wordpress-chat" ]; check $? "an absent key passes --no-wordpress-chat"

# Missing file, ref, or repo are hard failures recorded through record.
hard_fail() { rm -f "$TMP/record"; ( host_config_collect_flags ) >/dev/null 2>&1 && return 1; grep -qx "$1" "$TMP/record"; }
( HOST_CONFIG_PATH=hosts/missing.conf; hard_fail host-config-missing ); check $? "a missing file in the repo fails hard"
( HOST_CONFIG_REF=no-such-branch; hard_fail host-config-fetch-failed ); check $? "a missing ref fails hard"
( HOST_CONFIG_REPO="$TMP/no-such-repo.git" HOST_CONFIG_MIRROR="$TMP/var/other-mirror.git"; hard_fail host-config-fetch-failed ); check $? "a missing repo fails hard"

# Without HOST_CONFIG_REPO the collect pass is a no-op: behavior unchanged.
flags_when_unset="$( HOST_CONFIG_REPO=""; host_config_collect_flags && printf '%s' "${HOST_CONFIG_FLAGS[*]-}" )"
[ -z "$flags_when_unset" ]; check $? "no host config repo: no flags, behavior unchanged"

# The wrapper wires it fail-closed: flags are collected before upgrade.sh and
# the invocation carries them; the file is read from the mirror, never a tree.
grep -q 'host_config_collect_flags' "$W"; check $? "cmd_apply collects host config flags"
apply_body="$(sed -n '/^cmd_apply() {/,/^}/p' "$W")"
printf '%s\n' "$apply_body" | grep -n 'host_config_collect_flags\|./upgrade.sh' | sort -n | head -1 | grep -q host_config_collect_flags; check $? "flags are collected before upgrade.sh runs"
printf '%s\n' "$apply_body" | grep -q 'HOST_CONFIG_FLAGS\[@\]'; check $? "upgrade.sh invocation carries the validated flags"
grep -q 'git --git-dir="\$HOST_CONFIG_MIRROR" show "refs/heads/\$HOST_CONFIG_REF:\$HOST_CONFIG_PATH"' "$W"; check $? "the file is read with git show from the bare mirror's ref"
grep -q 'source\|eval' <<< "$(sed -n '/^host_config_parse() {/,/^}/p' "$W")"; [ $? -ne 0 ]; check $? "the host config file is never sourced or eval'd"

echo
if [ "$FAIL" -gt 0 ]; then echo "FAIL: $FAIL assertion(s)"; exit 1; fi
echo "PASS: tests/self-upgrade.sh ($PASS assertions)"
