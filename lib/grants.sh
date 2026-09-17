#!/bin/bash
# The single path by which a privilege grant reaches a managed host.
#
# WHY THIS EXISTS
#
# A sudoers grant is the most consequential file this harness writes. It is also
# the one that was written two different ways.
#
# `lib/systems-capabilities.sh` grew a correct installer — validate a temp file,
# move it into place only once `visudo` accepts it — and then its only consumer
# was retired, leaving the mechanism with zero call sites. The next component
# that needed a grant did not find it, and wrote its own, which installed the
# file at its live path and validated afterwards:
#
#     printf '%s\n' "$content" > /etc/sudoers.d/name   # live
#     visudo -cf /etc/sudoers.d/name                   # too late
#
# Under `set -e` a rejected file aborts the run and stays on disk. An invalid
# file in /etc/sudoers.d makes `sudo` refuse to run for every user on the host,
# including the operator's recovery path. So the duplicate was not merely
# redundant, it was the dangerous one.
#
# The fix is not a better installer. It is having exactly one, that every
# component routes through, whose result something can verify afterwards.
#
# DECLARE, THEN APPLY
#
# Components declare grants; this file installs them. The declaration is
# readable without installing anything, which is what lets verify.sh assert that
# what is on the host is what some component actually asked for — rather than
# a file nobody owns, which is the state three of the four grants on the first
# host to get this were in.

GRANTS_SUDOERS_DIR="${GRANTS_SUDOERS_DIR:-/etc/sudoers.d}"

GRANT_DECLARED_NAMES=()
GRANT_DECLARED_CONTENT=()

grant_effective_uid() { printf '%s\n' "${WP_CODING_AGENTS_TEST_EUID:-$(id -u)}"; }

grant_file() { printf '%s/%s' "$GRANTS_SUDOERS_DIR" "$1"; }

# caller runas command-with-optional-glob -> one sudoers line.
grant_render_line() {
  printf '%s ALL=(%s) NOPASSWD: %s\n' "$1" "$2" "$3"
}

# Record a grant without touching the host. Re-declaring a name replaces it, so
# a component that computes its grant twice in one run cannot double-install.
#
# Content is held without a trailing newline — the shape command substitution
# yields — and every write and comparison below adds exactly one back, so a
# declaration and the file it produces cannot disagree by an invisible byte.
grant_declare() {
  local name="$1" content="$2" i=0
  while [ "$i" -lt "${#GRANT_DECLARED_NAMES[@]}" ]; do
    if [ "${GRANT_DECLARED_NAMES[$i]}" = "$name" ]; then
      GRANT_DECLARED_CONTENT[$i]="$content"
      return 0
    fi
    i=$((i + 1))
  done
  GRANT_DECLARED_NAMES+=("$name")
  GRANT_DECLARED_CONTENT+=("$content")
}

grant_declared_names() {
  [ "${#GRANT_DECLARED_NAMES[@]}" -gt 0 ] || return 0
  printf '%s\n' "${GRANT_DECLARED_NAMES[@]}"
}

grant_declared_content() {
  local name="$1" i=0
  while [ "$i" -lt "${#GRANT_DECLARED_NAMES[@]}" ]; do
    if [ "${GRANT_DECLARED_NAMES[$i]}" = "$name" ]; then
      printf '%s' "${GRANT_DECLARED_CONTENT[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# True when the installed file says what the declaration says.
grant_content_matches() {
  local file="$1" content="$2"
  [ -f "$file" ] || return 1
  printf '%s\n' "$content" | cmp -s - "$file"
}

# True when the file is owned the way sudo requires. A grant with the right
# words in it but the wrong ownership is not a correct grant: sudo ignores a
# group-writable policy file, and a non-root-owned one is an escalation path.
grant_ownership_ok() {
  local file="$1"
  [ -f "$file" ] || return 1
  [ "$(file_owner "$file" 2>/dev/null || true)" = "root" ] || return 1
  [ "$(file_group "$file" 2>/dev/null || true)" = "root" ] || return 1
  [ "$(file_mode "$file" 2>/dev/null || true)" = "440" ] || return 1
}

# The full invariant: right content, right ownership.
grant_matches() {
  grant_content_matches "$1" "$2" && grant_ownership_ok "$1"
}

# Validate content in isolation. Never runs against a path that sudo reads, so
# a rejected policy cannot affect the host.
grant_validate() {
  local content="$1" tmp rc=0
  command -v visudo >/dev/null 2>&1 || return 0
  tmp="$(mktemp)" || return 1
  printf '%s\n' "$content" > "$tmp"
  visudo -cf "$tmp" >/dev/null 2>&1 || rc=1
  rm -f "$tmp"
  return "$rc"
}

# Install a declared grant: validate first, then replace atomically. The file at
# the live path is only ever a policy visudo has already accepted.
grant_install() {
  local name="$1" content="$2" file tmp
  file="$(grant_file "$name")"

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE:-}[dry-run]${NC:-} Would install privilege grant: $file"
    return 0
  fi

  # Report and return rather than exiting. Whether a refused grant is fatal is
  # the caller's decision — the kimaki bridge treats it as fatal, a census or a
  # dry run does not — and a library that exits takes that choice away.
  if ! grant_validate "$content"; then
    warn "Refusing to install an invalid privilege grant: $file"
    return 1
  fi

  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  printf '%s\n' "$content" > "$tmp"

  if [ "$(grant_effective_uid)" -eq 0 ]; then
    chown root:root "$tmp"
  fi
  chmod 0440 "$tmp"
  mv "$tmp" "$file"
}

# Install every declared grant. Returns non-zero if any failed, having still
# attempted the rest: one broken declaration should not silently drop the others.
grant_apply_declared() {
  local name content rc=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    content="$(grant_declared_content "$name")" || continue
    grant_install "$name" "$content" || rc=1
  done <<EOF
$(grant_declared_names)
EOF
  return "$rc"
}

# Grant files present on the host that no component declared. These are not
# necessarily wrong — an operator may have placed one deliberately — but nothing
# reinstalls them after a rebuild, and nothing notices when they change.
grant_undeclared_files() {
  local file name
  [ -d "$GRANTS_SUDOERS_DIR" ] || return 0
  for file in "$GRANTS_SUDOERS_DIR"/*; do
    [ -f "$file" ] || continue
    name="$(basename "$file")"
    case "$name" in
      README|*~|*.*) continue ;;  # sudo itself ignores these
    esac
    grant_declared_content "$name" >/dev/null 2>&1 || printf '%s\n' "$name"
  done
}
