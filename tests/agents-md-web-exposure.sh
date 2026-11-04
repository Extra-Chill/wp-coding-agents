#!/bin/bash
# Root-level Markdown nginx protection and advisory exposure checks.
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/lib/infrastructure.sh"
source "$SCRIPT_DIR/lib/agents-md-guidance.sh"

log() { :; }
warn() { printf 'WARN: %s\n' "$*"; }
run_cmd() { :; }
write_file() { :; }
MODE=fresh DRY_RUN=true PHP_VERSION=8.3
SITE_DOMAIN=example.com SITE_PATH=/var/www/example
for topology in subdomain subdirectory single; do
  MULTISITE=true MULTISITE_TYPE="$topology"
  [ "$topology" != single ] || MULTISITE=false
  setup_nginx
  [[ "$NGINX_CONFIG" == *'location ~ ^/[^/]+\.md$ {
        return 404;
    }'* ]]
done

# Override the HTTP hook, including transport failure independently of status.
agents_md_web_http_status() {
  printf '%s\n' "$1" >> "$TRACE"
  case "$1" in
    https:*) [ "$HTTPS_STATUS" != unreachable ] || return 7; printf '%s' "$HTTPS_STATUS" ;;
    http:*) [ "$HTTP_STATUS" != unreachable ] || return 7; printf '%s' "$HTTP_STATUS" ;;
  esac
}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TRACE="$TMP/requests"
DRY_RUN=false
while read -r HTTPS_STATUS HTTP_STATUS expected; do
  : > "$TRACE"
  output=$(warn_if_agents_md_public 2>&1)
  if [ "$expected" = silent ]; then
    [ -z "$output" ]
  else
    [[ "$output" == *"$expected://example.com/AGENTS.md"* ]]
    [[ "$output" == *'location ~ ^/[^/]+\.md$ { return 404; }'* ]]
    [[ "$output" == *'<FilesMatch "^(AGENTS|CLAUDE)\.md$"> Require all denied </FilesMatch>'* ]]
  fi
  if [ "$HTTPS_STATUS" = unreachable ]; then
    [ "$(wc -l < "$TRACE")" -eq 2 ]
  else
    [ "$(wc -l < "$TRACE")" -eq 1 ]
  fi
done <<'CASES'
200 unreachable https
404 200 silent
403 200 silent
unreachable 200 http
unreachable 404 silent
unreachable 403 silent
unreachable unreachable silent
CASES

HTTPS_STATUS=200 HTTP_STATUS=200
for SITE_DOMAIN in '' localhost demo.local 127.0.0.1; do
  : > "$TRACE"
  [ -z "$(warn_if_agents_md_public 2>&1)" ]
  [ ! -s "$TRACE" ]
done
SITE_DOMAIN=example.com DRY_RUN=true
[ -z "$(warn_if_agents_md_public 2>&1)" ]
[ ! -s "$TRACE" ]
printf 'PASS: agent Markdown web exposure\n'
