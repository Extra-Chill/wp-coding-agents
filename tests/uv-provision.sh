#!/bin/bash
# Offline tests: real archives/checksums, fake release transport, no network.
set -eu
cd "$(dirname "$0")/.."
source lib/common.sh
source lib/systems-capabilities.sh
source lib/uv-provision.sh
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
UV_PROVISION_LIB_DIR="$TMP/lib/uv"
UV_PROVISION_BIN_DIR="$TMP/bin"
export SYSTEMS_CAPABILITIES_PROFILE=managed-vps
LOCAL_MODE=false
DRY_RUN=false
UPDATED_ITEMS=()
mkdir -p "$TMP/stubs" "$TMP/fixture/uv-x86_64-unknown-linux-gnu"
export FIXTURE="$TMP/release.tar.gz" FETCH_LOG="$TMP/fetch.log"
printf '#!/bin/sh\necho "uv %s"\n' "$UV_PROVISION_VERSION" > "$TMP/fixture/uv-x86_64-unknown-linux-gnu/uv"
printf '#!/bin/sh\nexit 0\n' > "$TMP/fixture/uv-x86_64-unknown-linux-gnu/uvx"
chmod +x "$TMP/fixture/uv-x86_64-unknown-linux-gnu/"*
tar -czf "$FIXTURE" -C "$TMP/fixture" uv-x86_64-unknown-linux-gnu
cat > "$TMP/stubs/curl" <<'STUB'
#!/bin/bash
set -eu
echo "$*" >> "$FETCH_LOG"
[ "${FETCH_FAIL:-0}" = 0 ] || exit 22
url="$2"
out="$4"
case "$url" in
  *.sha256)
    if [ "${BAD_SHA:-0}" = 1 ]; then printf '%064d\n' 0 > "$out"
    else sha256sum "$FIXTURE" > "$out"; fi ;;
  *) cp "$FIXTURE" "$out" ;;
esac
STUB
cat > "$TMP/stubs/uname" <<'STUB'
#!/bin/sh
echo "${TEST_ARCH:-x86_64}"
STUB
chmod +x "$TMP/stubs/"*
PATH="$TMP/stubs:$PATH"
export PATH

DRY_RUN=true
out="$(uv_provision_apply)"
[[ "$out" == *'[dry-run]'* ]] || fail 'dry-run intent missing'
[ ! -e "$FETCH_LOG" ] && [ ! -e "$UV_PROVISION_LIB_DIR" ] || fail 'dry-run changed host'
DRY_RUN=false
LOCAL_MODE=true
uv_provision_apply
[ ! -e "$FETCH_LOG" ] || fail 'local mode fetched'
LOCAL_MODE=false
SYSTEMS_CAPABILITIES_PROFILE=''
uv_provision_apply
[ ! -e "$FETCH_LOG" ] || fail 'disabled profile fetched'
SYSTEMS_CAPABILITIES_PROFILE=managed-vps

# Exercise the actual EUID guard even when CI runs these tests as root.
nonroot='source lib/common.sh; source lib/systems-capabilities.sh; source lib/uv-provision.sh; SYSTEMS_CAPABILITIES_PROFILE=managed-vps; LOCAL_MODE=false; DRY_RUN=false; uv_provision_apply'
if [ "$EUID" -eq 0 ]; then
  out="$(setpriv --reuid=65534 --regid=65534 --clear-groups bash -c "$nonroot")"
else
  out="$(bash -c "$nonroot")"
fi
[[ "$out" == *'requires root'* ]] || fail 'non-root did not warn'
[ ! -e "$FETCH_LOG" ] || fail 'non-root fetched'

export BAD_SHA=1
if uv_provision_download; then fail 'accepted bad checksum'; fi
[ ! -e "$UV_PROVISION_LIB_DIR/uv" ] || fail 'installed unverified binary'
export BAD_SHA=0 FETCH_FAIL=1
if uv_provision_download; then fail 'accepted failed download'; fi
export FETCH_FAIL=0
export TEST_ARCH=unsupported
if uv_provision_download; then fail 'accepted unsupported architecture'; fi
export TEST_ARCH=x86_64

# Keep installation tests portable to non-root developers; only the root gate
# is bypassed here, after the real non-root refusal has been checked above.
apply_test() {
  if [ "$EUID" -eq 0 ]; then uv_provision_apply; else
    uv_provision_apply_as_root
  fi
}
apply_definition="$(declare -f uv_provision_apply)"
apply_definition="${apply_definition/uv_provision_apply/uv_provision_apply_as_root}"
eval "${apply_definition/'${EUID:-$(id -u)}'/0}"
export FETCH_FAIL=1
apply_test
[ ! -e "$UV_PROVISION_LIB_DIR/uv" ] || fail 'failed fetch installed binary'
export FETCH_FAIL=0
apply_test
uv_provision_healthy || fail 'installed binary unhealthy'
[ -x "$UV_PROVISION_LIB_DIR/uvx" ] || fail 'uvx missing'
[ "$(readlink "$UV_PROVISION_BIN_DIR/uv")" = "$UV_PROVISION_LIB_DIR/uv" ] || fail 'uv link missing'
[ "$(readlink "$UV_PROVISION_BIN_DIR/uvx")" = "$UV_PROVISION_LIB_DIR/uvx" ] || fail 'uvx link missing'
[ "${#UPDATED_ITEMS[@]}" -gt 0 ] || fail 'changes not recorded'
grep -Fq "/$UV_PROVISION_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz" "$FETCH_LOG" || fail 'wrong release asset'
cp "$FETCH_LOG" "$TMP/fetch-before"
UPDATED_ITEMS=()
export FETCH_FAIL=1
apply_test
cmp -s "$FETCH_LOG" "$TMP/fetch-before" || fail 'healthy install fetched again'
[ "${#UPDATED_ITEMS[@]}" -eq 0 ] || fail 'healthy install recorded changes'
UV_PROVISION_VERSION=0.0.0
if uv_provision_healthy; then fail 'wrong version considered healthy'; fi
echo 'uv-provision: all assertions passed'
