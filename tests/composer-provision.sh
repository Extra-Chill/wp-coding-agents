#!/bin/bash
# tests/composer-provision.sh — regression tests for the managed-vps
# harness-owned Composer (#624).
#
# The property worth protecting is that nothing here ever executes an
# installer whose SHA-384 hash does not match the signature getcomposer.org
# publishes for it. Everything else — healthy detection, dry-run, non-root
# refusal — follows the same soft-fail shape lib/codebox-database.sh and the
# rest of lib/systems-capabilities.sh already use.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

source lib/common.sh
source lib/systems-capabilities.sh
source lib/composer-provision.sh

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

COMPOSER_PROVISION_LIB_DIR="$TMP/lib"
COMPOSER_PROVISION_BIN_DIR="$TMP/bin"
mkdir -p "$COMPOSER_PROVISION_LIB_DIR" "$COMPOSER_PROVISION_BIN_DIR"

echo "==> wrapper content"
CONTENT="$(composer_provision_wrapper_content)"
assert_contains "wrapper execs php against the harness-owned phar" "$CONTENT" "exec php \"$(composer_provision_phar)\""

echo ""
echo "==> healthy detection"
if composer_provision_healthy; then
  echo "  FAIL a missing phar is reported healthy"
  FAIL=$((FAIL + 1))
else
  echo "  ok   a missing phar is not reported healthy"
fi

STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
touch "$(composer_provision_phar)"

cat > "$STUB_BIN/php" <<'PHP'
#!/bin/bash
# Stub php: composer --version with no stderr noise, unless PHP_STUB_NOISE=1.
if [ "${PHP_STUB_NOISE:-0}" = 1 ]; then
  echo "Deprecation Notice: Constant E_STRICT is deprecated" >&2
fi
echo "Composer version 2.10.3 2026-01-01 00:00:00"
PHP
chmod +x "$STUB_BIN/php"
PATH="$STUB_BIN:$PATH"

if composer_provision_healthy; then
  echo "  ok   a phar with a clean php --version is reported healthy"
  PASS=$((PASS + 1))
else
  echo "  FAIL a phar with a clean php --version is reported healthy"
  FAIL=$((FAIL + 1))
fi

export PHP_STUB_NOISE=1
if composer_provision_healthy; then
  echo "  FAIL a phar emitting deprecation noise is reported healthy"
  FAIL=$((FAIL + 1))
else
  echo "  ok   a phar emitting deprecation noise on stderr is not reported healthy"
  PASS=$((PASS + 1))
fi
export PHP_STUB_NOISE=0

echo ""
echo "==> the installer is never executed when the signature does not match"
cat > "$STUB_BIN/curl" <<'CURL'
#!/bin/bash
# Stub curl: serves a fixed installer body and a signature that does NOT match
# it, so composer_provision_download must refuse before ever running php on
# the installer.
for arg in "$@"; do
  case "$arg" in
    *installer.sig) echo "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"; exit 0 ;;
  esac
done
out=""
prev=""
for arg in "$@"; do
  [ "$prev" = "-o" ] && out="$arg"
  prev="$arg"
done
echo '<?php echo "not the real installer";' > "${out:-/dev/stdout}"
CURL
chmod +x "$STUB_BIN/curl"

cat > "$STUB_BIN/php" <<'PHP'
#!/bin/bash
# Second stub: hash_file() returns the real hash of whatever curl wrote, and
# --install-dir would prove the installer ran if it reached that far.
for arg in "$@"; do
  case "$arg" in
    --install-dir=*) echo "COMPOSER INSTALLER RAN — signature check did not stop it" >&2; exit 1 ;;
  esac
done
if printf '%s' "$*" | grep -q 'hash_file'; then
  file="$(printf '%s' "$*" | grep -oE "/[^']+composer-setup\.php")"
  sha384sum "$file" 2>/dev/null | awk '{print $1}' || echo "deadbeef"
  exit 0
fi
echo "Composer version 2.10.3"
PHP
chmod +x "$STUB_BIN/php"

rm -f "$(composer_provision_phar)"
RC=0
composer_provision_download >"$TMP/download.out" 2>&1 || RC=$?
assert_eq "download refuses on a signature mismatch" "1" "$RC"
[ ! -f "$(composer_provision_phar)" ] && echo "  ok   no phar is written when the signature does not match" || { echo "  FAIL a phar was written despite a signature mismatch"; FAIL=$((FAIL + 1)); }
if grep -q 'COMPOSER INSTALLER RAN' "$TMP/download.out"; then
  echo "  FAIL the installer executed despite the signature mismatch — refusal is cosmetic"
  FAIL=$((FAIL + 1))
else
  echo "  ok   the installer never runs when the signature does not match"
  PASS=$((PASS + 1))
fi

echo ""
echo "==> the installer IS executed once the signature matches"
cat > "$STUB_BIN/curl" <<'CURL'
#!/bin/bash
# Second curl stub: signature now matches whatever curl serves as the
# installer body.
out=""
prev=""
for arg in "$@"; do
  [ "$prev" = "-o" ] && out="$arg"
  prev="$arg"
done
if [ -n "$out" ]; then
  echo '<?php echo "not the real installer";' > "$out"
  exit 0
fi
for arg in "$@"; do
  case "$arg" in
    *installer.sig)
      echo '<?php echo "not the real installer";' > /tmp/.composer-sig-fixture.$$
      sha384sum /tmp/.composer-sig-fixture.$$ | awk '{print $1}'
      rm -f /tmp/.composer-sig-fixture.$$
      exit 0
      ;;
  esac
done
CURL
chmod +x "$STUB_BIN/curl"

RC=0
composer_provision_download >"$TMP/download-ok.out" 2>&1 || RC=$?
assert_eq "download reports failure once the (fake) installer runs and errors as designed" "1" "$RC"
if grep -q 'COMPOSER INSTALLER RAN' "$TMP/download-ok.out"; then
  echo "  ok   the installer runs once the signature matches"
  PASS=$((PASS + 1))
else
  echo "  FAIL the installer did not run despite a matching signature"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "==> dry-run leaves the host untouched"
DRY_RUN=true
LOCAL_MODE=false
SYSTEMS_CAPABILITIES_PROFILE=managed-vps
OUT="$(composer_provision_apply)"
assert_contains "dry-run announces intent" "$OUT" "[dry-run]"
[ ! -f "$(composer_provision_wrapper)" ] && echo "  ok   dry-run writes no wrapper" || { echo "  FAIL dry-run wrote a wrapper"; FAIL=$((FAIL + 1)); }

echo ""
echo "==> disabled outside the managed-vps profile"
DRY_RUN=false
SYSTEMS_CAPABILITIES_PROFILE=""
OUT="$(composer_provision_apply)"
assert_eq "apply is silent when the profile is not managed-vps" "" "$OUT"

echo ""
echo "==> real provisioning refuses without root rather than failing the run"
SYSTEMS_CAPABILITIES_PROFILE=managed-vps
DRY_RUN=false
if [ "$(id -u)" -ne 0 ]; then
  RC=0
  OUT="$(composer_provision_apply)" || RC=$?
  assert_contains "warns that root is required" "$OUT" "requires root"
  assert_eq "still exits 0 — a soft failure must not abort the caller under set -e" "0" "$RC"
else
  echo "  skip running as root — cannot exercise the non-root refusal path"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "composer-provision: all $PASS assertions passed"
else
  echo "composer-provision: $FAIL of $((PASS + FAIL)) assertions failed"
  exit 1
fi
