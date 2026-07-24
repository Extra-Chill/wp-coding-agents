#!/bin/bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
cleanup() {
  chmod -R u+w "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

export SITE_PATH="$TMP/site"
export PLATFORM=mac
export DRY_RUN=false
mkdir -p "$SITE_PATH/wp-admin" "$SITE_PATH/wp-includes" "$SITE_PATH/wp-content/plugins" "$SITE_PATH/wp-content/themes"
SITE_PATH=$(cd "$SITE_PATH" && pwd -P)
export SITE_PATH

log() { :; }
source "$SCRIPT_DIR/lib/runtime-boundary.sh"

runtime_boundary_install
PROFILE=$(runtime_boundary_profile_path)
LAUNCHER=$(runtime_boundary_launcher_path)
[ -f "$PROFILE" ]
[ -x "$LAUNCHER" ]
[ "$(stat -f %Lp "$PROFILE" 2>/dev/null || stat -c %a "$PROFILE")" = "444" ]

HASH_BEFORE=$(md5 -q "$PROFILE" 2>/dev/null || md5sum "$PROFILE" | cut -d' ' -f1)
runtime_boundary_install
HASH_AFTER=$(md5 -q "$PROFILE" 2>/dev/null || md5sum "$PROFILE" | cut -d' ' -f1)
[ "$HASH_BEFORE" = "$HASH_AFTER" ]

for protected in wp-admin wp-includes wp-content/plugins wp-content/themes; do
  if "$LAUNCHER" /usr/bin/touch "$SITE_PATH/$protected/write-probe" 2>/dev/null; then
    echo "FAIL: sandbox allowed write to $protected"
    exit 1
  fi
  [ ! -e "$SITE_PATH/$protected/write-probe" ]
done

mkdir -p "$TMP/worktree/plugin"
ln -s "$TMP/worktree/plugin" "$SITE_PATH/wp-content/plugins/linked-plugin"
if "$LAUNCHER" /usr/bin/true 2>/dev/null; then
  echo "FAIL: launch preflight accepted an external symlink in protected source"
  exit 1
fi
unlink "$SITE_PATH/wp-content/plugins/linked-plugin"

"$LAUNCHER" /usr/bin/touch "$SITE_PATH/wp-content/write-probe"
[ -f "$SITE_PATH/wp-content/write-probe" ]

SYSTEMD=$(runtime_boundary_systemd_directives)
for protected in wp-admin wp-includes wp-content/plugins wp-content/themes; do
  echo "$SYSTEMD" | grep -Fq "ReadOnlyPaths=$SITE_PATH/$protected"
done
echo "$SYSTEMD" | grep -Fq 'NoNewPrivileges=true'
echo "$SYSTEMD" | grep -Fq 'PrivateMounts=true'
echo "$SYSTEMD" | grep -Fq 'CapabilityBoundingSet='
echo "$SYSTEMD" | grep -Fq 'AmbientCapabilities='
echo "$SYSTEMD" | grep -Fq 'ProtectProc=invisible'
echo "$SYSTEMD" | grep -Fq 'ExecStartPre=/usr/bin/python3'

START=$(runtime_boundary_start_command opencode)
echo "$START" | grep -Fq "$LAUNCHER"

echo "PASS: runtime write boundary"
