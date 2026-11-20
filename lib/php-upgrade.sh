#!/bin/bash
# lib/php-upgrade.sh — let the agent account apply PHP security patches.
#
# Installs scripts/wp-coding-agents-php-upgrade as a root-owned command and a
# sudoers grant for the service user limited to `start` and `status`. See the
# script header for the scope: same-name, already-installed `php<ver>-*`
# packages only, so a patch release can be applied but the PHP minor can never
# change and nothing new is installed or removed.
#
# Managed VPS installs only, with a non-root service user (a root agent needs
# no grant). Unlike the self-upgrade command, this one runs nothing from the
# checkout at runtime: the installed copy is a root-owned file the agent cannot
# write, so it does not need the checkout lock.
#
# Depends on lib/self-upgrade.sh (self_upgrade_euid, self_upgrade_write) and
# lib/grants.sh, both loaded before this file by setup.sh and upgrade.sh.

PHP_UPGRADE_BIN="${PHP_UPGRADE_BIN:-/usr/local/sbin/wp-coding-agents-php-upgrade}"
PHP_UPGRADE_GRANT="wp-coding-agents-php-upgrade"

php_upgrade_grant_content() {
  grant_render_line "$SERVICE_USER" root "$PHP_UPGRADE_BIN start, $PHP_UPGRADE_BIN status"
}

php_upgrade_apply() {
  [ "${LOCAL_MODE:-false}" = false ] || return 0
  [ "${EXTERNAL_WORDPRESS:-false}" != true ] || return 0
  [ -n "${SERVICE_USER:-}" ] && [ "$SERVICE_USER" != root ] || return 0

  local content
  content="$(php_upgrade_grant_content)"

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE:-}[dry-run]${NC:-} Would install $PHP_UPGRADE_BIN and grant $PHP_UPGRADE_GRANT for $SERVICE_USER"
    return 0
  fi
  if [ "$(self_upgrade_euid)" -ne 0 ]; then
    log "PHP upgrade command needs root to install; skipped (non-root run)"
    return 0
  fi

  self_upgrade_write "$PHP_UPGRADE_BIN" 0755 < "$SCRIPT_DIR/scripts/wp-coding-agents-php-upgrade"
  grant_declare "$PHP_UPGRADE_GRANT" "$content"
  if grant_install "$PHP_UPGRADE_GRANT" "$content"; then
    log "Agent PHP security upgrade: sudo $PHP_UPGRADE_BIN start (as $SERVICE_USER)"
  else
    warn "PHP upgrade grant was refused; the command is installed but $SERVICE_USER cannot run it"
  fi
}
