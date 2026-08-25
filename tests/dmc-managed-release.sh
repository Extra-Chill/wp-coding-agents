#!/bin/bash
# Deterministic coverage for copied DMC official-release updates.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/dmc-managed-release.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SITE_PATH="$TMP/site"
TIMESTAMP="test"
DRY_RUN=false
INSTALL_DATA_MACHINE=true
BLUE=""; NC=""
declare -a UPDATED_ITEMS=()
LOG=""
log() { LOG="$LOG$*\n"; }
warn() { LOG="$LOG$*\n"; }
fix_ownership() { :; }
ACTIVATIONS=0
ACTIVE=true
activate_plugin() { ACTIVATIONS=$((ACTIVATIONS + 1)); ACTIVE=true; }
wp_cmd() { [ "$ACTIVE" = true ] && [ "$1 $2 $3" = "plugin is-active data-machine-code" ]; }
fail() { echo "FAIL: $1" >&2; exit 1; }

PLUGIN="$SITE_PATH/wp-content/plugins/data-machine-code"
mkdir -p "$PLUGIN"
printf '<?php\n/*\n * Version: 1.0.0\n */\n' > "$PLUGIN/data-machine-code.php"

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN" "$TMP/release/data-machine-code"
printf '<?php\n/*\n * Version: 2.0.0\n */\n' > "$TMP/release/data-machine-code/data-machine-code.php"
(cd "$TMP/release" && zip -qr "$TMP/dmc.zip" data-machine-code)
SHA="$(shasum -a 256 "$TMP/dmc.zip" | awk '{print $1}')"
SHA_UPPER="$(printf '%s' "$SHA" | tr '[:lower:]' '[:upper:]')"
printf '%s  dmc.zip\n' "$SHA" > "$TMP/dmc.zip.sha256"
cat > "$FAKE_BIN/curl" <<'SH'
#!/bin/bash
set -eu
if [[ "$*" == *"releases/latest"* ]]; then
  printf '%s' "$DMC_TEST_RELEASE_JSON"
elif [[ "$*" == *"dmc.zip.sha256"* ]]; then cp "$DMC_TEST_CHECKSUM" "${@: -1}"
elif [[ "$*" == *"dmc.zip"* ]]; then cp "$DMC_TEST_ARCHIVE" "${@: -1}"
else exit 1
fi
SH
chmod +x "$FAKE_BIN/curl"
export PATH="$FAKE_BIN:$PATH" DMC_TEST_ARCHIVE="$TMP/dmc.zip" DMC_TEST_CHECKSUM="$TMP/dmc.zip.sha256"
DMC_TEST_RELEASE_JSON="{\"tag_name\":\"v2.0.0\",\"assets\":[{\"name\":\"dmc.zip\",\"browser_download_url\":\"https://release/dmc.zip\",\"digest\":\"sha256:$SHA_UPPER\"}]}"
export DMC_TEST_RELEASE_JSON
DMC_MANAGED_RELEASE_API="https://test/releases/latest"

# copied + dry-run: resolves the channel but leaves the deployment untouched.
DRY_RUN=true
before="$(shasum -a 256 "$PLUGIN/data-machine-code.php")"
out="$(update_data_machine_code_copied_release)"
case "$out" in *"SHA-256 verify"*) : ;; *) fail "dry-run did not describe checksum verification";; esac
case "$out" in *"$SHA"*) : ;; *) fail "dry-run did not carry the normalized GitHub digest";; esac
[ "$before" = "$(shasum -a 256 "$PLUGIN/data-machine-code.php")" ] || fail "dry-run mutated copied plugin"

# current copied install: no download/deploy and no update record.
DRY_RUN=false
printf '<?php\n/*\n * Version: 2.0.0\n */\n' > "$PLUGIN/data-machine-code.php"
mkdir -p "$PLUGIN/.wp-coding-agents-releases/current"
printf '<?php\n/*\n * Version: 2.0.0\n */\n' > "$PLUGIN/.wp-coding-agents-releases/current/data-machine-code.php"
printf '{"repository":"Extra-Chill/data-machine-code","version":"2.0.0","sha256":"%s"}\n' "$SHA" > "$PLUGIN/.wp-coding-agents-releases/current/.wp-coding-agents-managed-release.json"
ln -s .wp-coding-agents-releases/current "$PLUGIN/.wp-coding-agents-release-current"
UPDATED_ITEMS=(); LOG=""
update_data_machine_code_copied_release
case "$LOG" in *"already at official release 2.0.0"*) : ;; *) fail "current copied install was not recognized";; esac
[ "${#UPDATED_ITEMS[@]}" -eq 0 ] || fail "current copied install recorded an update"

# GitHub digest mismatch: preserve the old deployment.
rm -rf "$PLUGIN"
mkdir -p "$PLUGIN"
printf '<?php\n/*\n * Version: 1.0.0\n */\n' > "$PLUGIN/data-machine-code.php"
DMC_TEST_RELEASE_JSON='{"tag_name":"v2.0.0","assets":[{"name":"dmc.zip","browser_download_url":"https://release/dmc.zip","digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}]}'
LOG=""
update_data_machine_code_copied_release
[ "$(dmc_managed_release_header_version "$PLUGIN")" = "1.0.0" ] || fail "GitHub digest mismatch replaced deployment"
[ ! -e "$PLUGIN/.wp-coding-agents-release-current" ] || fail "GitHub digest mismatch mutated release pointers"
case "$LOG" in *"SHA-256 verification"*) : ;; *) fail "GitHub digest mismatch was not reported";; esac
DMC_TEST_RELEASE_JSON="{\"tag_name\":\"v2.0.0\",\"assets\":[{\"name\":\"dmc.zip\",\"browser_download_url\":\"https://release/dmc.zip\",\"digest\":\"sha256:$SHA_UPPER\"}]}"

# copied deployment: stage, preserve a fallback, activate, and record provenance.
mkdir -p "$PLUGIN/obsolete"
UPDATED_ITEMS=()
update_data_machine_code_copied_release
[ "$(dmc_managed_release_header_version "$PLUGIN")" = "2.0.0" ] || fail "copied release did not deploy target version"
[ -f "$(dmc_managed_release_provenance_file)" ] || fail "copied release provenance missing"
[ -f "$PLUGIN/.wp-coding-agents-release-current/data-machine-code.php" ] || fail "copied release current pointer missing"
[ ! -e "$PLUGIN/.wp-coding-agents-release-current/obsolete" ] || fail "copied release included stale files"
[ "${#UPDATED_ITEMS[@]}" -eq 1 ] || fail "copied release was not recorded"

# Interruption after writing the new loader but before switching current is
# recovered from the already verified staged release without another download.
target_pointer="$(readlink "$PLUGIN/.wp-coding-agents-release-current")"
rm -f "$PLUGIN/.wp-coding-agents-release-current"
mkdir -p "$PLUGIN/.wp-coding-agents-releases/interrupted-old"
printf '<?php\n/*\n * Version: 1.0.0\n */\n' > "$PLUGIN/.wp-coding-agents-releases/interrupted-old/data-machine-code.php"
ln -s .wp-coding-agents-releases/interrupted-old "$PLUGIN/.wp-coding-agents-release-current"
archive="$DMC_TEST_ARCHIVE"; DMC_TEST_ARCHIVE="$TMP/missing.zip"; export DMC_TEST_ARCHIVE
UPDATED_ITEMS=(); LOG=""
update_data_machine_code_copied_release
DMC_TEST_ARCHIVE="$archive"; export DMC_TEST_ARCHIVE
[ "$(readlink "$PLUGIN/.wp-coding-agents-release-current")" = "$target_pointer" ] || fail "interrupted loader/pointer state did not select the verified staged release"
[ "$(dmc_managed_release_header_version "$PLUGIN/.wp-coding-agents-release-current")" = "2.0.0" ] || fail "interrupted loader/pointer recovery left stale code active"
[ "${#UPDATED_ITEMS[@]}" -eq 1 ] || fail "interrupted loader/pointer recovery was not recorded"
case "$LOG" in *"Recovered Data Machine Code 2.0.0 release pointer"*) : ;; *) fail "interrupted loader/pointer recovery was not reported";; esac

# Legacy checksum sidecars remain accepted and verified before deployment.
rm -rf "$PLUGIN"
mkdir -p "$PLUGIN"
printf '<?php\n/*\n * Version: 1.0.0\n */\n' > "$PLUGIN/data-machine-code.php"
DMC_TEST_RELEASE_JSON='{"tag_name":"v2.0.0","assets":[{"name":"dmc.zip","browser_download_url":"https://release/dmc.zip?download=1"},{"name":"dmc.zip.sha256","browser_download_url":"https://release/dmc.zip.sha256"}]}'
DRY_RUN=true
out="$(update_data_machine_code_copied_release)"
case "$out" in *"https://release/dmc.zip.sha256"*) : ;; *) fail "legacy dry-run did not carry the checksum sidecar URL";; esac
status="$(dmc_managed_release_status)"
case "$status" in *'"checksum_url":"https://release/dmc.zip.sha256"'*) : ;; *) fail "legacy channel status omitted the checksum sidecar URL";; esac
DRY_RUN=false
printf '%064d  dmc.zip\n' 0 > "$TMP/dmc.zip.sha256"
LOG=""
update_data_machine_code_copied_release
[ "$(dmc_managed_release_header_version "$PLUGIN")" = "1.0.0" ] || fail "legacy checksum mismatch replaced deployment"
[ ! -e "$PLUGIN/.wp-coding-agents-release-current" ] || fail "legacy checksum mismatch mutated release pointers"
case "$LOG" in *"SHA-256 verification"*) : ;; *) fail "legacy checksum mismatch was not reported";; esac
printf '%s  dmc.zip\n' "$SHA" > "$TMP/dmc.zip.sha256"
UPDATED_ITEMS=()
update_data_machine_code_copied_release
[ "$(dmc_managed_release_header_version "$PLUGIN")" = "2.0.0" ] || fail "legacy checksum sidecar did not deploy target version"
[ "${#UPDATED_ITEMS[@]}" -eq 1 ] || fail "legacy checksum sidecar release was not recorded"
DMC_TEST_RELEASE_JSON="{\"tag_name\":\"v2.0.0\",\"assets\":[{\"name\":\"dmc.zip\",\"browser_download_url\":\"https://release/dmc.zip\",\"digest\":\"sha256:$SHA_UPPER\"}]}"

# An inactive plugin remains inactive; deployment does not call activation.
rm -rf "$PLUGIN"
mkdir -p "$PLUGIN"
printf '<?php\n/*\n * Version: 1.0.0\n */\n' > "$PLUGIN/data-machine-code.php"
ACTIVE=false; ACTIVATIONS=0; UPDATED_ITEMS=()
update_data_machine_code_copied_release
[ "$ACTIVE" = false ] || fail "inactive plugin became active"
[ "$ACTIVATIONS" -eq 0 ] || fail "inactive plugin activation was attempted"

# Simulate interruption after current -> previous. Recovery restores a complete
# release pointer before the next deployment attempt.
mv "$PLUGIN/.wp-coding-agents-release-current" "$PLUGIN/.wp-coding-agents-release-previous"
dmc_managed_release_recover "$PLUGIN"
[ -f "$PLUGIN/.wp-coding-agents-release-current/data-machine-code.php" ] || fail "interrupted update recovery left no runnable release"

# Malformed tags are rejected before download/deployment.
rm -rf "$PLUGIN"
mkdir -p "$PLUGIN"
printf '<?php\n/*\n * Version: 1.0.0\n */\n' > "$PLUGIN/data-machine-code.php"

# Present-but-malformed GitHub evidence is rejected rather than downgraded.
DMC_TEST_RELEASE_JSON="{\"tag_name\":\"v2.0.0\",\"assets\":[{\"name\":\"dmc.zip\",\"browser_download_url\":\"https://release/dmc.zip\",\"digest\":\"sha512:$SHA\"},{\"name\":\"dmc.zip.sha256\",\"browser_download_url\":\"https://release/dmc.zip.sha256\"}]}"
LOG=""
update_data_machine_code_copied_release
[ "$(dmc_managed_release_header_version "$PLUGIN")" = "1.0.0" ] || fail "malformed GitHub digest replaced deployment"
case "$LOG" in *"Could not resolve"*) : ;; *) fail "malformed GitHub digest was not rejected";; esac

# Releases without either recognized evidence form fail closed.
DMC_TEST_RELEASE_JSON='{"tag_name":"v2.0.0","assets":[{"name":"dmc.zip","browser_download_url":"https://release/dmc.zip"}]}'
LOG=""
update_data_machine_code_copied_release
[ "$(dmc_managed_release_header_version "$PLUGIN")" = "1.0.0" ] || fail "missing digest evidence replaced deployment"
case "$LOG" in *"Could not resolve"*) : ;; *) fail "missing digest evidence was not rejected";; esac

# Tuple delimiters in release metadata are rejected before download/deployment.
DMC_TEST_RELEASE_JSON='{"tag_name":"v2.0.0","assets":[{"name":"dmc.zip","browser_download_url":"https://release/dmc.zip\tinvalid","digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}]}'
LOG=""
update_data_machine_code_copied_release
[ "$(dmc_managed_release_header_version "$PLUGIN")" = "1.0.0" ] || fail "delimiter-bearing metadata replaced deployment"
case "$LOG" in *"Could not resolve"*) : ;; *) fail "delimiter-bearing metadata was not rejected";; esac

DMC_TEST_RELEASE_JSON='{"tag_name":"release-latest","assets":[{"name":"dmc.zip","browser_download_url":"https://release/dmc.zip"},{"name":"dmc.zip.sha256","browser_download_url":"https://release/dmc.zip.sha256"}]}'
LOG=""
update_data_machine_code_copied_release
[ "$(dmc_managed_release_header_version "$PLUGIN")" = "1.0.0" ] || fail "malformed tag replaced deployment"
case "$LOG" in *"Could not resolve"*) : ;; *) fail "malformed tag was not rejected";; esac
DMC_TEST_RELEASE_JSON="{\"tag_name\":\"v2.0.0\",\"assets\":[{\"name\":\"dmc.zip\",\"browser_download_url\":\"https://release/dmc.zip\",\"digest\":\"sha256:$SHA_UPPER\"}]}"

# Channel status uses the same resolver and exposes the deterministic digest.
status="$(dmc_managed_release_status)"
case "$status" in *'"deployment":"copied_deploy"'*'"latest_version":"2.0.0"'*"\"expected_sha256\":\"$SHA\""*) : ;; *) fail "copied channel status incorrect: $status";; esac

# git checkout: preserve the existing tagged-release path, never resolve assets.
mkdir -p "$PLUGIN/.git"
LOG=""
update_data_machine_code_copied_release
[ -z "$LOG" ] || fail "git checkout entered copied-release updater"

# The channel helper distinguishes copied installs from git installs.
status="$(dmc_managed_release_status)"
case "$status" in *'"deployment":"git_checkout"'*) : ;; *) fail "git channel status incorrect: $status";; esac

echo "dmc-managed-release tests passed"
