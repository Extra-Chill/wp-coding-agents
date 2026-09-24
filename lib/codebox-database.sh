#!/bin/bash
# managed-vps: a least-privilege MySQL/MariaDB user for Codebox/Homeboy test
# harnesses.
#
# WHY THIS EXISTS
#
# Components whose Homeboy config declares
#   wp_codebox_database_service: { provider: "external", engine: "mysql",
#     secret_env: { host: "WP_CODEBOX_DB_HOST", ... } }
# cannot run `homeboy review test` or `homeboy release` unless
# WP_CODEBOX_DB_HOST/PORT/USER/PASSWORD are present in the agent's environment.
#
# The only credentials an agent on a managed VPS can otherwise reach are the
# site's own (wp-config.php): ALL privileges on the production database, no
# CREATE DATABASE. Pointing a test harness at that account is the wrong
# direction to fail in — a broken test run should not be able to touch
# production data, and that account cannot create the scratch databases a
# test suite needs anyway. This provisions a separate, narrowly-scoped account
# instead: CREATE/DROP/DML limited to a `codebox_%` database-name pattern,
# nothing on the site database, no global privileges.
#
# Credentials are generated once, stored root-owned (0600) outside the web
# root, and reach the agent service exactly the way the WP AI Gateway token
# does (lib/ai-gateway.sh): an EnvironmentFile=- line on the kimaki systemd
# unit (see bridges/kimaki.sh), read by the service manager (root) before it
# drops to the service user — so the file itself never needs to be readable by
# anything but root.

CODEBOX_DATABASE_ENV_FILE="${CODEBOX_DATABASE_ENV_FILE:-/etc/wp-coding-agents/codebox-db.env}"
CODEBOX_DATABASE_USER="${CODEBOX_DATABASE_USER:-wp_coding_agents_codebox}"
CODEBOX_DATABASE_HOST="${CODEBOX_DATABASE_HOST:-127.0.0.1}"
CODEBOX_DATABASE_PORT="${CODEBOX_DATABASE_PORT:-3306}"
# The db-name pattern a test harness may CREATE/DROP/use. Escaped so the
# underscore matches only a literal underscore rather than MySQL's "any single
# character" wildcard — tighter than what an unescaped pattern would grant.
CODEBOX_DATABASE_PATTERN="${CODEBOX_DATABASE_PATTERN:-codebox\\_%}"
CODEBOX_DATABASE_MYSQL_BIN="${CODEBOX_DATABASE_MYSQL_BIN:-mysql}"

codebox_database_enabled() { systems_capabilities_enabled; }

# Read a KEY=value pair out of the env file this module writes. Deliberately
# not shared with lib/ai-gateway.sh's ai_gateway_read_env_value: that reader
# also matches an `export KEY=` form because it reads a file a human might
# hand-edit. This file is only ever written by codebox_database_apply, in the
# one form below, so the extra branch would be untested dead weight.
codebox_database_env_value() {
  local key="$1" file="$2" line
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key"=*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done < "$file"
}

# Reuse the existing password unless a rotation was explicitly requested — the
# same convention lib/ai-gateway.sh uses for ROTATE_AI_GATEWAY_TOKEN. A test
# harness credential that silently changes on every upgrade run breaks whatever
# already has it cached (a running homeboy session, an operator's shell).
codebox_database_password() {
  local existing
  existing="$(codebox_database_env_value WP_CODEBOX_DB_PASSWORD "$CODEBOX_DATABASE_ENV_FILE")"
  if [ -n "$existing" ] && [ "${ROTATE_CODEBOX_DB_PASSWORD:-false}" != true ]; then
    printf '%s' "$existing"
  else
    # Hex, not base64: the password is interpolated into a single-quoted SQL
    # literal and a shell-quoted env value below, and hex's restricted
    # alphabet (0-9a-f) needs no escaping in either context.
    openssl rand -hex 24
  fi
}

codebox_database_env_content() {
  local password="$1"
  printf 'WP_CODEBOX_DB_HOST=%s\nWP_CODEBOX_DB_PORT=%s\nWP_CODEBOX_DB_USER=%s\nWP_CODEBOX_DB_PASSWORD=%s\n' \
    "$CODEBOX_DATABASE_HOST" "$CODEBOX_DATABASE_PORT" "$CODEBOX_DATABASE_USER" "$password"
}

# The SQL that provisions the account. CREATE USER IF NOT EXISTS is a full
# no-op for an existing user — it does not update the password — so re-running
# this with a freshly generated password when one already existed is safe: the
# new value is simply discarded, and codebox_database_password() above already
# prefers the existing one for exactly that reason.
#
# The GRANT is scoped to the `codebox_%` pattern only: no ON *.*, no access to
# the site database, no WITH GRANT OPTION. That is the whole security
# invariant this module exists to hold, so it lives in one place rather than
# being reconstructed at each call site.
codebox_database_provision_sql() {
  local password="$1"
  cat <<SQL
CREATE USER IF NOT EXISTS '$CODEBOX_DATABASE_USER'@'$CODEBOX_DATABASE_HOST' IDENTIFIED BY '$password';
GRANT ALL PRIVILEGES ON \`$CODEBOX_DATABASE_PATTERN\`.* TO '$CODEBOX_DATABASE_USER'@'$CODEBOX_DATABASE_HOST';
FLUSH PRIVILEGES;
SQL
}

# Write the credential file atomically: root:root 0600, outside the web root,
# never briefly readable by anyone else. Mirrors grant_install's
# validate/write-to-temp/rename-into-place shape in lib/grants.sh, minus the
# validation step (there is nothing here for visudo's counterpart to check).
codebox_database_write_env_file() {
  local password="$1" tmp
  mkdir -p "$(dirname "$CODEBOX_DATABASE_ENV_FILE")"
  tmp="$(mktemp "${CODEBOX_DATABASE_ENV_FILE}.XXXXXX")" || return 1
  printf '%s' "$(codebox_database_env_content "$password")" > "$tmp"
  if [ "$(id -u)" -eq 0 ]; then
    chown root:root "$tmp"
  fi
  chmod 0600 "$tmp"
  mv "$tmp" "$CODEBOX_DATABASE_ENV_FILE"
}

# Best-effort by design: this runs as part of the same systems-capabilities
# pass as journald/logrotate provisioning, invoked under `set -e`. A missing
# mysql client or a rejected GRANT should not abort the rest of an upgrade —
# it should be loud (warn) and leave WP_CODEBOX_DB_* absent, which is exactly
# what already blocked releases before this existed, not a new failure mode.
codebox_database_apply() {
  codebox_database_enabled || return 0
  [ "$LOCAL_MODE" = false ] || return 0

  local password
  password="$(codebox_database_password)"

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would provision MySQL user '$CODEBOX_DATABASE_USER'@'$CODEBOX_DATABASE_HOST' limited to \`$CODEBOX_DATABASE_PATTERN\`.*"
    echo -e "${BLUE}[dry-run]${NC} Would write $CODEBOX_DATABASE_ENV_FILE (root:root 0600, WP_CODEBOX_DB_* — password redacted)"
    return 0
  fi

  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    warn "Codebox test database provisioning requires root — run ./upgrade.sh --systems-capabilities managed-vps as root"
    return 0
  fi

  if ! command -v "$CODEBOX_DATABASE_MYSQL_BIN" >/dev/null 2>&1; then
    warn "$CODEBOX_DATABASE_MYSQL_BIN is not on PATH — cannot provision the codebox test database user"
    return 0
  fi

  log "Provisioning codebox test database user '$CODEBOX_DATABASE_USER'@'$CODEBOX_DATABASE_HOST'..."
  local provision_err
  provision_err="$(mktemp)" || return 0
  if ! "$CODEBOX_DATABASE_MYSQL_BIN" -e "$(codebox_database_provision_sql "$password")" 2>"$provision_err"; then
    warn "Could not provision the codebox test database user: $(cat "$provision_err" 2>/dev/null)"
    rm -f "$provision_err"
    return 0
  fi
  rm -f "$provision_err"

  if codebox_database_write_env_file "$password"; then
    UPDATED_ITEMS+=("Codebox test database user ($CODEBOX_DATABASE_ENV_FILE)")
  else
    warn "Provisioned the codebox test database user but could not write $CODEBOX_DATABASE_ENV_FILE"
  fi
  return 0
}
