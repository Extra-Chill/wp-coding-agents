#!/bin/bash
# Managed VPS policy must not expose an unowned process-inspection contract.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
ok() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; failures=$((failures + 1)); }

source lib/common.sh
source lib/systems-capabilities.sh
source lib/codebox-database.sh
source lib/composer-provision.sh
source lib/source-policy.sh
SITE_PATH="$TMP/site"
DM_WORKSPACE_DIR="$TMP/workspace"
SERVICE_USER="$(id -un)"
SERVICE_GROUP="$(id -gn)"
DRY_RUN=true
LOCAL_MODE=false
SYSTEMS_CAPABILITIES_PROFILE=managed-vps
SYSTEMS_CAPABILITIES_PROFILE_ROOT="$TMP/profiles"
SYSTEMS_CAPABILITIES_LIB_DIR="$TMP/lib"
SYSTEMS_CAPABILITIES_BIN_DIR="$TMP/bin"
SYSTEMS_CAPABILITIES_JOURNALD_FILE="$TMP/journald.conf"
SYSTEMS_CAPABILITIES_LOGROTATE_DIR="$TMP/logrotate"
SYSTEMS_CAPABILITIES_SYSTEMD_DIR="$TMP/systemd"
SYSTEMS_CAPABILITIES_SUDOERS_DIR="$TMP/sudoers"
SYSTEMS_CAPABILITIES_EUID=0
SOURCE_LOG_PATHS="$(printf '%s\n' "$TMP/php/php8.4-fpm.log" "$TMP/php/logs" "$TMP/php/php8.4-fpm-link.log" "$TMP/php/other.log")"
mkdir -p "$SITE_PATH/wp-content" "$DM_WORKSPACE_DIR/repo" "$TMP/php"
touch "$SITE_PATH/wp-content/debug.log" "$TMP/php/php8.4-fpm.log" "$TMP/php/php8.4-fpm.log.1" "$TMP/php/php8.4-fpm.log.2" "$TMP/php/target.log" "$TMP/php/other.log"
mkdir "$TMP/php/logs"
ln -s "$TMP/php/target.log" "$TMP/php/php8.4-fpm-link.log"
chmod 750 "$TMP/php"
chmod 700 "$TMP/php/logs"
chmod 600 "$SITE_PATH/wp-content/debug.log"
mkdir -p "$SYSTEMS_CAPABILITIES_LOGROTATE_DIR"
cat > "$SYSTEMS_CAPABILITIES_LOGROTATE_DIR/php8.4-fpm" <<EOF
$TMP/php/php8.4-fpm.log {
    weekly
    rotate 12
    compress
    reopenlogs
}
EOF

codebox_database_apply() { :; }
composer_provision_apply() { :; }
systemctl() { :; }
CHOWN_CALLS="$TMP/chown-calls"
chown() { printf '%s %s\n' "$1" "$2" >> "$CHOWN_CALLS"; }
systems_capabilities_status() { :; }

echo "systems capability policy remains exact and bounded"
[ "$(systems_capabilities_journald_content)" = $'[Journal]\nSystemMaxUse=1G' ] && ok "journald cap is 1G" || fail "journald cap changed"
policy="$(systems_capabilities_logrotate_content)"
for directive in daily 'maxsize 100M' 'rotate 7' compress copytruncate 'su www-data www-data' 'create 0640 www-data www-data'; do
  case "$policy" in *"$directive"*) ;; *) fail "logrotate policy misses $directive" ;; esac
done
[ "$(systems_capabilities_logrotate_content | grep -c "$TMP/php/php8.4-fpm.log")" -eq 0 ] && ok "external PHP-FPM log has no duplicate stanza" || fail "external PHP-FPM log got a duplicate stanza"
timer="$(systems_capabilities_logrotate_timer_content)"
for directive in 'OnCalendar=' 'OnCalendar=*:0/5' 'AccuracySec=1min' 'RandomizedDelaySec=0' 'Persistent=true'; do
  case "$timer" in *"$directive"*) ;; *) fail "logrotate timer misses $directive" ;; esac
done
[ "$(systems_capabilities_logrotate_timer_file)" = "$SYSTEMS_CAPABILITIES_SYSTEMD_DIR/logrotate.timer.d/wp-coding-agents.conf" ] && ok "logrotate cadence extends the owner timer" || fail "logrotate timer path is not fixed"
case "$(systems_capabilities_profile_content)" in *'process_inspection'*) fail "retired inspection contract remains discoverable" ;; *) ok "profile omits the unowned inspection contract" ;; esac
case "$(systems_capabilities_profile_content)" in *'"timer":"logrotate.timer"'*'"schedule":"*:0/5"'*) ok "logrotate timer contract remains discoverable" ;; *) fail "logrotate timer contract missing" ;; esac

echo "retired process probes are removed"
mkdir -p "$SYSTEMS_CAPABILITIES_LIB_DIR" "$SYSTEMS_CAPABILITIES_SUDOERS_DIR"
touch "$SYSTEMS_CAPABILITIES_LIB_DIR/dmc-process-inspect" "$SYSTEMS_CAPABILITIES_LIB_DIR/process-inspect" "$(systems_capabilities_retired_sudoers_file)"
DRY_RUN=false
systems_capabilities_cleanup_retired_process_probe
[ ! -e "$SYSTEMS_CAPABILITIES_LIB_DIR/dmc-process-inspect" ] && [ ! -e "$SYSTEMS_CAPABILITIES_LIB_DIR/process-inspect" ] && [ ! -e "$(systems_capabilities_retired_sudoers_file)" ] && ok "retired process probes are removed" || fail "retired process probe cleanup failed"

echo "non-root repair is explicit and dry-run does not write"
DRY_RUN=false
systems_capabilities_apply > "$TMP/initial.out"
config="$(systems_capabilities_logrotate_file)"
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
[ "$(mode "$TMP/php/php8.4-fpm.log")" = 640 ] && [ "$(mode "$TMP/php/php8.4-fpm.log.1")" = 640 ] && [ "$(mode "$TMP/php/php8.4-fpm.log.2")" = 640 ] && [ "$(mode "$TMP/php/logs")" = 700 ] && [ "$(mode "$TMP/php")" = 750 ] && [ "$(mode "$SITE_PATH/wp-content/debug.log")" = 600 ] && [ "$(mode "$TMP/php/target.log")" = 644 ] && [ "$(mode "$TMP/php/other.log")" = 644 ] && [ "$(grep -F -x -c "root:$SERVICE_GROUP $TMP/php/php8.4-fpm.log" "$CHOWN_CALLS")" -eq 1 ] && [ "$(grep -F -x -c "root:$SERVICE_GROUP $TMP/php/php8.4-fpm.log.1" "$CHOWN_CALLS")" -eq 1 ] && [ "$(grep -F -x -c "root:$SERVICE_GROUP $TMP/php/php8.4-fpm.log.2" "$CHOWN_CALLS")" -eq 1 ] && ok "initial apply repairs scoped log permissions" || fail "initial log permission repair failed"
package_rule="$(< "$SYSTEMS_CAPABILITIES_LOGROTATE_DIR/php8.4-fpm")"
case "$package_rule" in *"su root root"*) ;; *) fail "package PHP-FPM rule lacks su root root" ;; esac
case "$package_rule" in *"create 0640 root $SERVICE_GROUP"*) ;; *) fail "package PHP-FPM rule lacks service-group create" ;; esac
case "$package_rule" in *weekly*rotate\ 12*compress*reopenlogs*) ok "package PHP-FPM rule is repaired in place" ;; *) fail "package PHP-FPM rule lost existing directives" ;; esac
first_hash="$(cksum "$config" | cut -d' ' -f1-2)"
systems_capabilities_apply > "$TMP/repeat.out"
[ "$first_hash" = "$(cksum "$config" | cut -d' ' -f1-2)" ] && ok "repeat apply is idempotent" || fail "repeat apply changed the logrotate rule"

SYSTEMS_CAPABILITIES_EUID=1000
before="$(cksum "$config" | cut -d' ' -f1-2)"
systems_capabilities_apply > "$TMP/no-root.out"
[ "$before" = "$(cksum "$config" | cut -d' ' -f1-2)" ] && grep -q 'root_repair_required' "$TMP/no-root.out" && ok "non-root apply reports repair without writing" || fail "non-root apply wrote or omitted repair"

DRY_RUN=true
repair="$(systems_capabilities_report_root_repair)"
case "$repair" in *root_repair_required*'--systems-capabilities managed-vps'*) ok "root repair is actionable" ;; *) fail "root repair contract missing" ;; esac
dry_hash="$(cksum "$SYSTEMS_CAPABILITIES_JOURNALD_FILE" | cut -d' ' -f1-2)"
systems_capabilities_apply > "$TMP/dry-run.out"
[ "$dry_hash" = "$(cksum "$SYSTEMS_CAPABILITIES_JOURNALD_FILE" | cut -d' ' -f1-2)" ] && ok "dry-run leaves host policy untouched" || fail "dry-run wrote policy"

[ "$failures" -eq 0 ] && echo "systems-capabilities: all assertions passed" || exit 1
