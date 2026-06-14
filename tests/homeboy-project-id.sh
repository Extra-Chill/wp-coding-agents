#!/bin/bash
# tests/homeboy-project-id.sh — Homeboy project id resolution for local sites.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/homeboy.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SITE_PATH="$TMP/intelligence-chubes4"
SITE_DOMAIN="localhost:8881"
DRY_RUN=false
LOCAL_MODE=true
mkdir -p "$SITE_PATH"

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/homeboy" <<'SH'
#!/bin/sh
if [ "$1 $2" = "project list" ]; then
  cat <<JSON
{"success":true,"data":{"projects":[
  {"domain":"intelligence-chubes4","id":"intelligence-chubes4"},
  {"domain":"example.test","id":"example"}
]}}
JSON
  exit 0
fi
if [ "$1 $2" = "project show" ]; then
  case "$3" in
    intelligence-chubes4)
      printf '{"success":true,"data":{"id":"intelligence-chubes4","entity":{"base_path":"%s"}}}\n' "$SITE_PATH"
      exit 0
      ;;
    example)
      printf '{"success":true,"data":{"id":"example","entity":{"base_path":"%s"}}}\n' "$TMP/example"
      exit 0
      ;;
  esac
fi
exit 2
SH
chmod +x "$FAKE_BIN/homeboy"
PATH="$FAKE_BIN:$PATH"
export SITE_PATH TMP

resolved="$(homeboy_project_id)"
if [ "$resolved" != "intelligence-chubes4" ]; then
  echo "FAIL: expected base_path match to resolve intelligence-chubes4, got '$resolved'"
  exit 1
fi

echo "OK: Homeboy project id resolves local Studio site by base_path"
