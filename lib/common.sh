#!/bin/bash
# Common utilities: colors, logging, command helpers

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[wp-coding-agents]${NC} $1"; }
warn() { echo -e "${YELLOW}[wp-coding-agents]${NC} $1"; }
error() { echo -e "${RED}[wp-coding-agents]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[wp-coding-agents]${NC} $1"; }

run_cmd() {
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} $*"
  else
    "$@"
  fi
}

write_file() {
  local file_path="$1"
  local content="$2"
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would write to $file_path"
  else
    echo "$content" > "$file_path"
  fi
}

# service_file_normalize_perms <file>
#
# Normalize ownership/mode of a service file wp-coding-agents just wrote
# under the web tree (mu-plugins, AGENTS.md + backups, runtime plugins,
# installed skills). These files are written by whichever identity ran
# setup/upgrade — root (cron/systemd, VPS upgrades), the service user
# (opencode, local dev), or www-data (WP-CLI fallback) — and then need to
# be *rewritten* by a different one of those identities on the next sync.
# Forcing 0644 (see issue #133) fixed the world-read bit PHP-FPM needs, but
# left files non-group-writable, so the next writer (a different uid than
# the last one) hits EACCES instead of relying on group membership.
#
# Fix: force 0664 (rw for owner+group, r for other) and chgrp to the
# webroot group, derived from the file's parent directory rather than
# hardcoded — sites vary in which group owns the web tree, and this stays
# correct without wp-coding-agents needing to know or assume "www-data".
# Failures are swallowed (non-root callers who aren't in the target group
# can't chgrp; that's fine, the mode fix alone still helps).
service_file_normalize_perms() {
  local file="$1"
  [ -n "$file" ] && [ -e "$file" ] || return 0

  local dir group
  dir="$(dirname -- "$file")"
  # GNU stat first (Linux); BSD/macOS stat as fallback for local dev mode.
  group="$(stat -c '%G' "$dir" 2>/dev/null || stat -f '%Sg' "$dir" 2>/dev/null || true)"

  chmod 0664 "$file" 2>/dev/null || true
  if [ -n "$group" ]; then
    chgrp "$group" "$file" 2>/dev/null || true
  fi
}

# service_dir_normalize_perms <dir>
#
# Recursive counterpart to service_file_normalize_perms, for directory
# trees wp-coding-agents copies into the web tree wholesale (installed
# skills). Normalizes every file and dir under <dir> to the group owning
# <dir>'s parent, with dirs getting the execute bit (0775) files 0664.
service_dir_normalize_perms() {
  local target="$1"
  [ -n "$target" ] && [ -d "$target" ] || return 0

  local parent group
  parent="$(dirname -- "$target")"
  group="$(stat -c '%G' "$parent" 2>/dev/null || stat -f '%Sg' "$parent" 2>/dev/null || true)"

  find "$target" -type d -exec chmod 0775 {} + 2>/dev/null || true
  find "$target" -type f -exec chmod 0664 {} + 2>/dev/null || true
  if [ -n "$group" ]; then
    chgrp -R "$group" "$target" 2>/dev/null || true
  fi
}

# Robust git clone for setup-time plugin/skill deps:
#   - Pins HTTP/1.1 to dodge intermittent GitHub HTTP/2 500s seen during
#     fresh setup runs.
#   - Rewrites SSH-style URLs (git@github.com:…) to HTTPS so users with
#     `gh auth status` reporting `Git operations protocol: ssh` but no SSH
#     key registered don't hit cryptic `Permission denied (publickey)`.
#   - Retries with exponential backoff (default 3 attempts: 2s, 4s, 8s)
#     and cleans up partial directories between attempts.
#
# Usage: git_clone_with_retry <url> <dir> [extra git-clone args…]
git_clone_with_retry() {
  local url="$1"
  local dir="$2"
  shift 2 || true
  local max_attempts=3
  local delay=2
  local attempt

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} git clone $url $dir $* (with HTTPS rewrite + HTTP/1.1 + retry)"
    return 0
  fi

  for attempt in $(seq 1 "$max_attempts"); do
    if git \
        -c http.version=HTTP/1.1 \
        -c "url.https://github.com/.insteadOf=git@github.com:" \
        clone "$@" "$url" "$dir"; then
      return 0
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      warn "Clone of $url failed (attempt $attempt/$max_attempts); retrying in ${delay}s..."
      rm -rf "$dir"
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done
  warn "Clone of $url failed after $max_attempts attempts."
  return 1
}
initialize_kimaki_overrides() {
  KIMAKI_UNIT_EXPLICIT=false
  KIMAKI_DATA_DIR_EXPLICIT=false
  KIMAKI_LOCK_PORT_EXPLICIT=false
  AGENT_SLUG_EXPLICIT=false

  if [ "${KIMAKI_UNIT+x}" = x ]; then
    KIMAKI_UNIT_EXPLICIT=true
  else
    KIMAKI_UNIT="kimaki.service"
  fi
  KIMAKI_LOCK_PORT="${KIMAKI_LOCK_PORT:-}"
  if [ -n "${KIMAKI_DATA_DIR:-}" ]; then
    KIMAKI_DATA_DIR_EXPLICIT=true
  fi
  if [ -n "$KIMAKI_LOCK_PORT" ]; then
    KIMAKI_LOCK_PORT_EXPLICIT=true
  fi
  if [ -n "${AGENT_SLUG:-}" ]; then
    AGENT_SLUG_EXPLICIT=true
  fi
}
