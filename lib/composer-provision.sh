#!/bin/bash
# managed-vps: keep a current Composer at a harness-owned path, independent of
# the distro package.
#
# WHY THIS EXISTS
#
# The distro `/usr/bin/composer` (Ubuntu 24.04, packaged Feb 2024) emits
# `Deprecation Notice: Constant E_STRICT is deprecated` on every invocation
# under PHP 8.4 — the constant it references was removed from PHP core.
# Homeboy's release `preflight.dependencies` treats any composer stderr output
# as a failure (exit 2), which blocks every component release on a host once
# PHP has moved past what the packaged Composer targets.
#
# getcomposer.org publishes the installer script plus a detached SHA-384
# signature (installer.sig) of it, specifically so a script like this one can
# fetch and verify it without trusting the transport alone. This provisions
# Composer at a path that is not /usr/bin/composer — so apt is never fighting
# this for ownership of that file — and installs a thin wrapper first on the
# service PATH (SYSTEMS_CAPABILITIES_BIN_DIR, already /usr/local/bin).

COMPOSER_PROVISION_LIB_DIR="${COMPOSER_PROVISION_LIB_DIR:-/usr/local/lib/wp-coding-agents/composer}"
COMPOSER_PROVISION_BIN_DIR="${COMPOSER_PROVISION_BIN_DIR:-${SYSTEMS_CAPABILITIES_BIN_DIR:-/usr/local/bin}}"
COMPOSER_PROVISION_INSTALLER_URL="${COMPOSER_PROVISION_INSTALLER_URL:-https://getcomposer.org/installer}"
COMPOSER_PROVISION_SIG_URL="${COMPOSER_PROVISION_SIG_URL:-https://composer.github.io/installer.sig}"

composer_provision_enabled() { systems_capabilities_enabled; }

composer_provision_phar() { printf '%s/composer.phar' "$COMPOSER_PROVISION_LIB_DIR"; }
composer_provision_wrapper() { printf '%s/composer' "$COMPOSER_PROVISION_BIN_DIR"; }

composer_provision_wrapper_content() {
  cat <<EOF
#!/bin/sh
# Installed by wp-coding-agents under the managed-vps systems capability
# profile. Do not edit; re-run ./upgrade.sh --systems-capabilities managed-vps
# to refresh it.
exec php "$(composer_provision_phar)" "\$@"
EOF
}

# True when the installed phar exists and runs clean on this host's PHP — no
# stderr output at all, which is exactly the property the distro package
# lacks on PHP 8.4 and exactly what Homeboy's dependency preflight checks for.
composer_provision_healthy() {
  local phar out
  phar="$(composer_provision_phar)"
  [ -f "$phar" ] || return 1
  command -v php >/dev/null 2>&1 || return 1
  out="$(php "$phar" --version 2>&1 1>/dev/null)" || return 1
  [ -z "$out" ]
}

# Download the installer and its detached signature separately, verify the
# installer's SHA-384 hash against the signature before ever executing it, and
# refuse outright if either fetch or the comparison fails. Nothing here runs
# unverified code — that is the entire reason getcomposer.org publishes the
# signature.
composer_provision_download() {
  local tmp_dir installer sig_expected sig_actual install_log
  tmp_dir="$(mktemp -d)" || return 1
  installer="$tmp_dir/composer-setup.php"
  install_log="$tmp_dir/install.log"

  if ! curl -fsSL "$COMPOSER_PROVISION_INSTALLER_URL" -o "$installer"; then
    warn "Could not download the Composer installer from $COMPOSER_PROVISION_INSTALLER_URL"
    rm -rf "$tmp_dir"
    return 1
  fi

  sig_expected="$(curl -fsSL "$COMPOSER_PROVISION_SIG_URL" 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$sig_expected" ]; then
    warn "Could not fetch the Composer installer signature from $COMPOSER_PROVISION_SIG_URL — refusing to install an unverified installer"
    rm -rf "$tmp_dir"
    return 1
  fi

  sig_actual="$(php -r "echo hash_file('sha384', '$installer');" 2>/dev/null)"
  if [ -z "$sig_actual" ] || [ "$sig_expected" != "$sig_actual" ]; then
    warn "Composer installer signature mismatch (expected $sig_expected, got ${sig_actual:-<none>}) — refusing to install"
    rm -rf "$tmp_dir"
    return 1
  fi

  mkdir -p "$COMPOSER_PROVISION_LIB_DIR"
  if ! php "$installer" --install-dir="$COMPOSER_PROVISION_LIB_DIR" --filename=composer.phar >"$install_log" 2>&1; then
    warn "Composer installer failed: $(tail -n 5 "$install_log")"
    rm -rf "$tmp_dir"
    return 1
  fi
  rm -rf "$tmp_dir"
  chmod 0755 "$(composer_provision_phar)"
}

# Best-effort, like codebox_database_apply: runs inside systems_capabilities_apply
# under `set -e`, so a network hiccup fetching Composer must not abort the rest
# of the upgrade. A stale or missing Composer here is the state every host was
# already in before this existed — not a new failure mode.
composer_provision_apply() {
  composer_provision_enabled || return 0
  [ "$LOCAL_MODE" = false ] || return 0

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would install/refresh Composer at $(composer_provision_phar)"
    echo -e "${BLUE}[dry-run]${NC} Would write wrapper $(composer_provision_wrapper)"
    return 0
  fi

  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    warn "Composer provisioning requires root — run ./upgrade.sh --systems-capabilities managed-vps as root"
    return 0
  fi

  if ! command -v php >/dev/null 2>&1; then
    warn "php is not on PATH — cannot provision Composer"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl is not on PATH — cannot provision Composer"
    return 0
  fi

  if composer_provision_healthy; then
    log "Composer at $(composer_provision_phar) is current and clean"
  else
    log "Installing/refreshing Composer at $(composer_provision_phar)..."
    if ! composer_provision_download; then
      warn "Composer provisioning failed — the service PATH may still resolve the distro composer"
      return 0
    fi
    UPDATED_ITEMS+=("Composer refreshed ($(composer_provision_phar))")
  fi

  systems_capabilities_write_exact "$(composer_provision_wrapper)" "$(composer_provision_wrapper_content)" 0755
  return 0
}
