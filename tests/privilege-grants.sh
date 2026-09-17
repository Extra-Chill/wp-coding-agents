#!/bin/bash
# Coverage for lib/grants.sh — the single path by which a privilege grant
# reaches a host.
#
# The property that matters is negative: an invalid policy must never exist at a
# path sudo reads, not even briefly, because an invalid file in /etc/sudoers.d
# makes sudo refuse to run for every user on the host — including the operator
# trying to undo it. The implementation this replaced wrote first and validated
# second, under `set -e`, so a rejected policy stayed on disk.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/grants.sh"

GRANTS_SUDOERS_DIR="$TMP/sudoers"
mkdir -p "$GRANTS_SUDOERS_DIR"
DRY_RUN=false
WP_CODING_AGENTS_TEST_EUID=1000   # exercise the non-root path; chown is skipped

PASS=0
FAIL=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'ok   %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$name" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

VALID="agent ALL=(root) NOPASSWD: /usr/local/sbin/thing *"
OTHER="agent ALL=(root) NOPASSWD: /usr/local/sbin/other *"
# visudo rejects this: no run-as spec, no command.
INVALID="this is not sudoers policy at all"

# ---------------------------------------------------------------------------
# Rendering and declaration
# ---------------------------------------------------------------------------

check "renders a sudoers line" \
  "agent ALL=(root) NOPASSWD: /usr/local/sbin/thing *" \
  "$(grant_render_line agent root '/usr/local/sbin/thing *')"

grant_declare demo "$VALID"
check "declares content" "$VALID" "$(grant_declared_content demo)"
check "declared name is listed" "demo" "$(grant_declared_names)"

grant_declare demo "$OTHER"
check "re-declaring replaces rather than appends" "$OTHER" "$(grant_declared_content demo)"
check "re-declaring does not duplicate the name" "1" "$(grant_declared_names | wc -l | tr -d ' ')"

grant_declare demo "$VALID"

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

grant_apply_declared
rc=$?
check "applying a valid declaration succeeds" 0 "$rc"
check "installed content matches the declaration" "$VALID" "$(cat "$TMP/sudoers/demo")"
check "installed grant is 0440" "440" "$(file_mode "$TMP/sudoers/demo")"
check "declaration and file agree on content" 0 "$(grant_content_matches "$TMP/sudoers/demo" "$VALID"; echo $?)"

# A grant is trailing-newline terminated exactly once: sudo needs the newline,
# and a second one would make every content comparison disagree forever.
check "file ends with exactly one newline" "1" \
  "$(python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); print(len(d)-len(d.rstrip(b"\n")))' "$TMP/sudoers/demo")"

# ---------------------------------------------------------------------------
# THE property: an invalid policy never reaches a path sudo reads
# ---------------------------------------------------------------------------

if command -v visudo >/dev/null 2>&1; then
  grant_install refused "$INVALID" >"$TMP/refused.out" 2>&1
  rc=$?
  check "installing invalid policy fails" 1 "$rc"
  check "no file is left at the live path" "absent" \
    "$([ -e "$TMP/sudoers/refused" ] && echo present || echo absent)"
  check "no temp file is left behind" "0" \
    "$(find "$TMP/sudoers" -name 'refused.*' | wc -l | tr -d ' ')"

  # The dangerous case: a host already has a working grant, and an upgrade
  # computes a broken one. The working grant must survive untouched.
  grant_install demo "$INVALID" >/dev/null 2>&1
  check "an existing valid grant survives a rejected update" "$VALID" "$(cat "$TMP/sudoers/demo")"
  check "surviving grant is still 0440" "440" "$(file_mode "$TMP/sudoers/demo")"
else
  printf 'skip visudo unavailable; cannot assert policy rejection\n'
fi

# ---------------------------------------------------------------------------
# Drift detection
# ---------------------------------------------------------------------------

# 0440 is read-only even to its owner, so simulating a hand edit needs the
# write bit back first -- exactly what an operator with sudo would do.
chmod 0644 "$TMP/sudoers/demo"
printf '%s\n' "$OTHER" > "$TMP/sudoers/demo"
chmod 0440 "$TMP/sudoers/demo"
check "content drift is detected" 1 "$(grant_content_matches "$TMP/sudoers/demo" "$VALID"; echo $?)"

chmod 0644 "$TMP/sudoers/demo"
printf '%s\n' "$VALID" > "$TMP/sudoers/demo"
check "permission drift is detected" 1 "$(grant_ownership_ok "$TMP/sudoers/demo"; echo $?)"
check "permission drift fails the full invariant" 1 "$(grant_matches "$TMP/sudoers/demo" "$VALID"; echo $?)"

check "a missing grant is detected" 1 "$(grant_content_matches "$TMP/sudoers/absent" "$VALID"; echo $?)"

# ---------------------------------------------------------------------------
# Census of grants nothing declared
# ---------------------------------------------------------------------------

printf '%s\n' "$OTHER" > "$TMP/sudoers/hand-placed"
check "undeclared grants are reported" "hand-placed" "$(grant_undeclared_files)"
printf '%s\n' "$OTHER" > "$TMP/sudoers/ignored.bak"
check "dotted names are ignored, as sudo ignores them" "hand-placed" "$(grant_undeclared_files)"

# ---------------------------------------------------------------------------
# Dry run touches nothing
# ---------------------------------------------------------------------------

DRY_RUN=true
grant_install dryrun "$VALID" >/dev/null 2>&1
check "dry-run installs nothing" "absent" \
  "$([ -e "$TMP/sudoers/dryrun" ] && echo present || echo absent)"
DRY_RUN=false

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'PASS: tests/privilege-grants.sh\n'
