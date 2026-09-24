#!/bin/bash
# tests/codebox-database.sh — regression tests for the managed-vps codebox
# test database provisioning (#624).
#
# The property that matters most is negative: the GRANT this module renders
# must never touch anything outside the codebox_% pattern — no ON *.*, no
# WITH GRANT OPTION, no reference to a site database name. Everything else
# (password reuse, dry-run, non-root refusal) is the same idempotence
# contract the rest of lib/systems-capabilities.sh already holds itself to.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

source lib/common.sh
source lib/systems-capabilities.sh
source lib/codebox-database.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ok   $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $label"
    echo "       expected: '$expected'"
    echo "       actual:   '$actual'"
    FAIL=$((FAIL + 1))
  fi
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) echo "  ok   $label"; PASS=$((PASS + 1)) ;;
    *) echo "  FAIL $label (missing: $needle)"; FAIL=$((FAIL + 1)) ;;
  esac
}
refute_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) echo "  FAIL $label (unexpectedly present: $needle)"; FAIL=$((FAIL + 1)) ;;
    *) echo "  ok   $label" ;;
  esac
}

CODEBOX_DATABASE_ENV_FILE="$TMP/codebox-db.env"

echo "==> env value reader"
printf 'WP_CODEBOX_DB_HOST=127.0.0.1\nWP_CODEBOX_DB_USER=bob\n' > "$TMP/fixture.env"
assert_eq "reads a matching key" "127.0.0.1" "$(codebox_database_env_value WP_CODEBOX_DB_HOST "$TMP/fixture.env")"
assert_eq "reads a second key" "bob" "$(codebox_database_env_value WP_CODEBOX_DB_USER "$TMP/fixture.env")"
assert_eq "missing key is empty" "" "$(codebox_database_env_value WP_CODEBOX_DB_PASSWORD "$TMP/fixture.env")"
assert_eq "missing file is empty" "" "$(codebox_database_env_value WP_CODEBOX_DB_HOST "$TMP/does-not-exist.env")"

echo ""
echo "==> env content rendering"
CONTENT="$(codebox_database_env_content secretvalue)"
assert_contains "renders host" "$CONTENT" "WP_CODEBOX_DB_HOST=$CODEBOX_DATABASE_HOST"
assert_contains "renders port" "$CONTENT" "WP_CODEBOX_DB_PORT=$CODEBOX_DATABASE_PORT"
assert_contains "renders user" "$CONTENT" "WP_CODEBOX_DB_USER=$CODEBOX_DATABASE_USER"
assert_contains "renders the password" "$CONTENT" "WP_CODEBOX_DB_PASSWORD=secretvalue"

echo ""
echo "==> the GRANT is scoped to the codebox_% pattern only — the security invariant"
SQL="$(codebox_database_provision_sql secretvalue)"
assert_contains "creates the user without erroring on re-run" "$SQL" "CREATE USER IF NOT EXISTS"
assert_contains "grants on the codebox pattern" "$SQL" "GRANT ALL PRIVILEGES ON \`codebox\\_%\`.* TO"
assert_contains "scoped to this host only" "$SQL" "'$CODEBOX_DATABASE_USER'@'$CODEBOX_DATABASE_HOST'"
refute_contains "never grants on every database" "$SQL" "ON *.*"
refute_contains "never grants globally" "$SQL" "ON \`*\`.*"
refute_contains "never grants the ability to grant" "$SQL" "WITH GRANT OPTION"
refute_contains "never names a specific non-pattern database" "$SQL" "\`wordpress\`"

echo ""
echo "==> password is generated once and reused, not rotated on every run"
PW1="$(codebox_database_password)"
[ -n "$PW1" ] && echo "  ok   generates a non-empty password" || { echo "  FAIL generates a non-empty password"; FAIL=$((FAIL + 1)); }
codebox_database_write_env_file "$PW1" >/dev/null 2>&1 || true
PW2="$(codebox_database_password)"
assert_eq "re-running reuses the same password" "$PW1" "$PW2"
ROTATE_CODEBOX_DB_PASSWORD=true
PW3="$(codebox_database_password)"
ROTATE_CODEBOX_DB_PASSWORD=false
if [ "$PW3" != "$PW1" ]; then
  echo "  ok   an explicit rotation request generates a new password"
  PASS=$((PASS + 1))
else
  echo "  FAIL an explicit rotation request generates a new password"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "==> the credential file is root-tight, not merely present"
[ "$(file_mode "$CODEBOX_DATABASE_ENV_FILE")" = "600" ] && echo "  ok   env file is 0600" || { echo "  FAIL env file is not 0600"; FAIL=$((FAIL + 1)); }

echo ""
echo "==> dry-run leaves the host untouched"
rm -f "$CODEBOX_DATABASE_ENV_FILE"
DRY_RUN=true
LOCAL_MODE=false
SYSTEMS_CAPABILITIES_PROFILE=managed-vps
OUT="$(codebox_database_apply)"
assert_contains "dry-run announces intent" "$OUT" "[dry-run]"
refute_contains "dry-run never prints the password" "$OUT" "$PW1"
[ ! -e "$CODEBOX_DATABASE_ENV_FILE" ] && echo "  ok   dry-run writes no credential file" || { echo "  FAIL dry-run wrote a credential file"; FAIL=$((FAIL + 1)); }

echo ""
echo "==> disabled outside the managed-vps profile"
DRY_RUN=false
SYSTEMS_CAPABILITIES_PROFILE=""
OUT="$(codebox_database_apply)"
assert_eq "apply is silent when the profile is not managed-vps" "" "$OUT"
[ ! -e "$CODEBOX_DATABASE_ENV_FILE" ] && echo "  ok   no credential file outside the profile" || { echo "  FAIL wrote a credential file outside the profile"; FAIL=$((FAIL + 1)); }

echo ""
echo "==> real provisioning refuses without root rather than failing the run"
SYSTEMS_CAPABILITIES_PROFILE=managed-vps
DRY_RUN=false
if [ "$(id -u)" -ne 0 ]; then
  RC=0
  OUT="$(codebox_database_apply)" || RC=$?
  assert_contains "warns that root is required" "$OUT" "requires root"
  assert_eq "still exits 0 — a soft failure must not abort the caller under set -e" "0" "$RC"
else
  echo "  skip running as root — cannot exercise the non-root refusal path"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "codebox-database: all $PASS assertions passed"
else
  echo "codebox-database: $FAIL of $((PASS + FAIL)) assertions failed"
  exit 1
fi
