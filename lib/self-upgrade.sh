#!/bin/bash
# lib/self-upgrade.sh — let the agent account upgrade its own install.
#
# Installs scripts/wp-coding-agents-upgrade as a root-owned command, its config,
# and a sudoers grant for the service user limited to `start` and `status`.
# See the script header for the trust model: only code merged to the trust ref
# of the root-owned checkout this upgrade runs from can ever run.
#
# Managed VPS installs only, with a non-root service user (a root agent needs
# no grant). The checkout must already be root-owned and locked down; if it is
# not, nothing is installed, because a writable checkout would make the grant a
# root shell.

SELF_UPGRADE_BIN="${SELF_UPGRADE_BIN:-/usr/local/sbin/wp-coding-agents-upgrade}"
SELF_UPGRADE_CONFIG="${SELF_UPGRADE_CONFIG:-/etc/wp-coding-agents/self-upgrade.conf}"
SELF_UPGRADE_GRANT="wp-coding-agents-self-upgrade"
SELF_UPGRADE_TRUST_REF="${SELF_UPGRADE_TRUST_REF:-main}"

self_upgrade_euid() { printf '%s\n' "${WP_CODING_AGENTS_TEST_EUID:-$(id -u)}"; }

# Root-owned and not writable by group or other, for the path and every parent.
self_upgrade_checkout_locked() {
  local path="$1" owner mode
  [ -d "$path/.git" ] || return 1
  while [ -n "$path" ] && [ "$path" != / ]; do
    owner="$(file_owner "$path" 2>/dev/null || true)"
    mode="$(file_mode "$path" 2>/dev/null || true)"
    [ "$owner" = root ] || return 1
    [ -n "$mode" ] && [ $(( 8#$mode & 8#022 )) -eq 0 ] || return 1
    path="$(dirname "$path")"
  done
}

self_upgrade_config_content() {
  printf 'CHECKOUT=%s\nSITE_PATH=%s\nTRUST_REF=%s\n' "$SCRIPT_DIR" "$SITE_PATH" "$SELF_UPGRADE_TRUST_REF"
}

self_upgrade_grant_content() {
  grant_render_line "$SERVICE_USER" root "$SELF_UPGRADE_BIN start, $SELF_UPGRADE_BIN status"
}

# Write via a temp file and rename: the running wrapper is replaced while it is
# executing upgrade.sh, and bash reads scripts incrementally, so the new
# content must land on a new inode.
self_upgrade_write() {
  local dest="$1" mode="$2" tmp
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp "$dest.XXXXXX")"
  cat > "$tmp"
  [ "$(self_upgrade_euid)" -ne 0 ] || chown root:root "$tmp"
  chmod "$mode" "$tmp"
  mv "$tmp" "$dest"
}

self_upgrade_apply() {
  [ "${LOCAL_MODE:-false}" = false ] || return 0
  [ "${EXTERNAL_WORDPRESS:-false}" != true ] || return 0
  [ -n "${SERVICE_USER:-}" ] && [ "$SERVICE_USER" != root ] || return 0

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE:-}[dry-run]${NC:-} Would install $SELF_UPGRADE_BIN, $SELF_UPGRADE_CONFIG and grant $SELF_UPGRADE_GRANT for $SERVICE_USER"
    return 0
  fi
  if [ "$(self_upgrade_euid)" -ne 0 ]; then
    log "Self-upgrade command needs root to install; skipped (non-root run)"
    return 0
  fi
  if ! self_upgrade_checkout_locked "$SCRIPT_DIR"; then
    warn "Not installing the agent self-upgrade command: $SCRIPT_DIR must be a root-owned git checkout that group/other cannot write."
    return 0
  fi

  local existing_site
  existing_site="$(sed -n 's/^SITE_PATH=//p' "$SELF_UPGRADE_CONFIG" 2>/dev/null | tail -1)"
  if [ -n "$existing_site" ] && [ "$existing_site" != "$SITE_PATH" ]; then
    warn "Self-upgrade is configured for $existing_site; leaving it (one site per host)."
    return 0
  fi

  self_upgrade_write "$SELF_UPGRADE_BIN" 0755 < "$SCRIPT_DIR/scripts/wp-coding-agents-upgrade"
  self_upgrade_config_content | self_upgrade_write "$SELF_UPGRADE_CONFIG" 0644
  grant_declare "$SELF_UPGRADE_GRANT" "$(self_upgrade_grant_content)"
  if grant_install "$SELF_UPGRADE_GRANT" "$(self_upgrade_grant_content)"; then
    log "Agent self-upgrade: sudo $SELF_UPGRADE_BIN start (as $SERVICE_USER)"
  else
    warn "Self-upgrade grant was refused; the command is installed but $SERVICE_USER cannot run it"
  fi
}
