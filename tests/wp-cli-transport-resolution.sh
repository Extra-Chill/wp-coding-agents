#!/bin/bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

log() { :; }
error() {
  printf 'ERROR: %s\n' "$1" >&2
  return 1
}

export SITE_PATH="$TMP/site"
mkdir -p "$SITE_PATH" "$TMP/bin"
export PATH="$TMP/bin:/usr/bin:/bin"
export DRY_RUN=false

cat > "$TMP/bin/studio" <<'SH'
#!/bin/bash
printf 'fixture database unavailable\n' >&2
exit 17
SH
chmod +x "$TMP/bin/studio"

WP_CLI_TRANSPORT_CANDIDATE_NAMES=()
WP_CLI_TRANSPORT_CANDIDATE_JSON=()
WP_CLI_TRANSPORT=()
wp_cli_transport_register_candidate direct missing-wp
wp_cli_transport_register_candidate studio studio wp
if wp_cli_transport_resolve_candidates 2> "$TMP/failure.log"; then
  echo "FAIL: unusable transport candidates resolved successfully"
  exit 1
fi
grep -F "direct: executable 'missing-wp' not found" "$TMP/failure.log" >/dev/null || {
  echo "FAIL: missing executable diagnostic was not preserved"
  exit 1
}
grep -F "studio: runtime probe failed: fixture database unavailable" "$TMP/failure.log" >/dev/null || {
  echo "FAIL: Studio probe diagnostic was not preserved"
  exit 1
}
[ "${#WP_CLI_TRANSPORT[@]}" -eq 0 ] || {
  echo "FAIL: failed resolution retained an unusable transport"
  exit 1
}

cat > "$TMP/bin/studio" <<'SH'
#!/bin/bash
[ "$1" = wp ] && [ "$2" = eval ] && exit 0
exit 2
SH
chmod +x "$TMP/bin/studio"
WP_CLI_TRANSPORT_CANDIDATE_NAMES=()
WP_CLI_TRANSPORT_CANDIDATE_JSON=()
wp_cli_transport_register_candidate direct missing-wp
wp_cli_transport_register_candidate studio studio wp
wp_cli_transport_resolve_candidates
[ "${WP_CLI_TRANSPORT[*]}" = "studio wp" ] || {
  echo "FAIL: usable Studio transport was not selected"
  exit 1
}

WP_CLI_TRANSPORT=()
WP_CLI_TRANSPORT_JSON='["configured-wp","--flag"]'
wp_cli_transport_resolve_candidates
[ "${WP_CLI_TRANSPORT[*]}" = "configured-wp --flag" ] || {
  echo "FAIL: explicit transport was not authoritative"
  exit 1
}

echo "OK: WordPress CLI transport resolution fails closed"
