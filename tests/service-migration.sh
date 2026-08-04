#!/bin/bash
# tests/service-migration.sh — root -> non-root service identity migration (#93).
#
# Three properties, in descending order of how badly they fail:
#
#   1. THE INVENTORY NEVER CARRIES A CREDENTIAL. The migration's actual security
#      payload is that /root stays 0700 and root-owned, so anything NOT in the
#      inventory becomes unreachable to the agent. An inventory that quietly
#      picks up `.ssh` doesn't fail loudly — it hands the migrated agent private
#      keys to every other machine in the fleet and looks like a successful
#      migration while doing it. These assertions are the reason the exclusion
#      list is enumerated rather than implied.
#
#   2. MANAGED GETS LESS THAN ENGINEERING. Posture is what decides whether the
#      dev toolchain and forge credentials come across. If the two postures ever
#      produce the same inventory, the file axis (#314) and the capability axis
#      (#327) have silently collapsed into one, and managed installs are running
#      with engineering reach.
#
#   3. --non-root ON A ROOT INSTALL FAILS CLOSED. This is the original #93
#      footgun: it renders User=opencode, creates no user, and repoints
#      KIMAKI_DATA_DIR at an empty home while the live session database stays in
#      /root. Refusing is the fix; a passing migration is no good if the broken
#      neighbouring flag is still reachable.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

FAILED=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [ "$got" = "$want" ]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name"
    echo "         got:  $got"
    echo "         want: $want"
    FAILED=$((FAILED + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) echo "  ok   $name" ;;
    *)
      echo "  FAIL $name (missing: $needle)"
      FAILED=$((FAILED + 1))
      ;;
  esac
}

refute_contains() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*)
      echo "  FAIL $name (unexpectedly present: $needle)"
      FAILED=$((FAILED + 1))
      ;;
    *) echo "  ok   $name" ;;
  esac
}

assert_excluded() {
  local rel="$1"
  if service_migration_is_excluded "$rel"; then
    echo "  ok   '$rel' is excluded"
  else
    echo "  FAIL '$rel' is NOT excluded — the migration would carry it to the agent"
    FAILED=$((FAILED + 1))
  fi
}

# Stubs for the helpers lib/common.sh normally provides.
log()  { echo "$1" >/dev/null; }
warn() { echo "$1" >/dev/null; }
info() { echo "$1" >/dev/null; }
error() { echo "ERROR: $1" >&2; exit 1; }

# shellcheck disable=SC1091
source lib/service-migration.sh

echo "service-migration: credential exclusion"

# Named exclusions.
for p in .ssh .secrets .pki .gnupg .aws .bash_history .mysql_history; do
  assert_excluded "$p"
done

# Anything beneath a named exclusion.
assert_excluded ".ssh/id_ed25519"
assert_excluded ".ssh/config"
assert_excluded ".secrets/database"

# Shape-based rules. These are what catch the operator-specific names that
# cannot be enumerated in shipped code (#320) — the install this was written
# against had .h44-secrets, .h44-target-dbpass, sweatpants-api-token.txt and
# opencode-auth-backup.json sitting in /root next to the agent's own state.
assert_excluded ".h44-secrets"
assert_excluded ".h44-target-dbpass"
assert_excluded "sweatpants-api-token.txt"
assert_excluded "sweatpants-signed-token-secret.txt"
assert_excluded "opencode-auth-backup.json"
assert_excluded "some-service.pem"
assert_excluded "deploy.key"

# And the inventories themselves must be clean under BOTH postures, which is
# the assertion that survives someone adding an entry to the lists later.
for posture in engineering managed; do
  inv="$(service_migration_inventory "$posture")"
  for bad in .ssh .secrets .pki .gnupg .aws .bash_history; do
    refute_contains "$inv" "$bad" "$posture inventory omits $bad"
  done
done

echo ""
echo "service-migration: posture shapes the inventory"

eng="$(service_migration_inventory engineering)"
man="$(service_migration_inventory managed)"

# Runtime state is what the agent IS — required under every posture, or the
# migrated service comes back with no sessions and no runtime auth.
for p in .kimaki .config/opencode .local/share/opencode; do
  assert_contains "$eng" "$p" "engineering carries $p"
  assert_contains "$man" "$p" "managed carries $p"
done

# Dev toolchain and forge credentials are engineering-only. A managed agent has
# no git, no GitHub, and no build step in its world (#314), so migrating these
# would widen its reach for a capability it is never asked to exercise.
for p in .cargo .rustup .bun .config/gh .gitconfig .homeboy; do
  assert_contains "$eng" "$p" "engineering carries $p"
  refute_contains "$man" "$p" "managed omits $p"
done

# The postures must not converge. If this fails, the capability distinction is
# gone regardless of what the individual assertions above say.
if [ "$eng" = "$man" ]; then
  echo "  FAIL engineering and managed inventories are identical"
  FAILED=$((FAILED + 1))
else
  echo "  ok   engineering and managed inventories differ"
fi

eng_count=$(printf '%s\n' "$eng" | grep -c . || true)
man_count=$(printf '%s\n' "$man" | grep -c . || true)
if [ "$man_count" -lt "$eng_count" ]; then
  echo "  ok   managed inventory is smaller ($man_count < $eng_count)"
else
  echo "  FAIL managed inventory ($man_count) is not smaller than engineering ($eng_count)"
  FAILED=$((FAILED + 1))
fi

echo ""
echo "service-migration: --migrate-extra escape hatch"

# The hatch exists because a shipped inventory cannot name install-specific
# state (#320). It must not become the route a credential travels.
(
  SERVICE_MIGRATION_EXTRA_PATHS=""
  service_migration_add_extra_path "homeboy-modules"
  service_migration_add_extra_path "go-sdk"
  inv="$(service_migration_inventory engineering)"
  assert_contains "$inv" "homeboy-modules" "extra path is carried"
  assert_contains "$inv" "go-sdk" "second extra path is carried"
  # And still absent from managed's runtime-only base set unless asked for.
  assert_contains "$(service_migration_inventory managed)" "homeboy-modules" \
    "extra paths apply under managed too"
) || FAILED=$((FAILED + 1))

for bad in .ssh .secrets deploy.key ".h44-target-dbpass"; do
  out=$(bash -c '
    source lib/service-migration.sh
    error() { echo "ERROR: $1"; exit 1; }
    service_migration_add_extra_path "'"$bad"'"
  ' 2>&1 || true)
  assert_contains "$out" "credential exclusion list" "--migrate-extra $bad is refused"
done

# Escaping the service home entirely would let the hatch reach anything on disk.
for bad in "/etc/shadow" "../root/.ssh"; do
  out=$(bash -c '
    source lib/service-migration.sh
    error() { echo "ERROR: $1"; exit 1; }
    service_migration_add_extra_path "'"$bad"'"
  ' 2>&1 || true)
  assert_contains "$out" "relative to the service home" "--migrate-extra $bad is refused"
done

echo ""
echo "service-migration: installed-identity read"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/units"
bridge_systemd_units() { echo "kimaki.service"; }

# No unit installed -> empty, so --migrate-non-root can tell "fresh install"
# apart from "installed and running as root".
SYSTEMD_UNIT_DIR="$TMP/units"
assert_eq "$(service_migration_installed_user)" "" "no unit yields empty identity"

printf '[Service]\nUser=root\nExecStart=/bin/true\n' >"$TMP/units/kimaki.service"
assert_eq "$(service_migration_installed_user)" "root" "reads User=root"

printf '[Service]\nUser=opencode\nExecStart=/bin/true\n' >"$TMP/units/kimaki.service"
assert_eq "$(service_migration_installed_user)" "opencode" "reads User=opencode"

echo ""
echo "service-migration: preflight fails closed"

# Local installs have no systemd and no service user to migrate onto.
out=$(LOCAL_MODE=true bash -c '
  source lib/service-migration.sh
  log() { :; }; warn() { :; }
  error() { echo "ERROR: $1"; exit 1; }
  service_migration_preflight opencode /root engineering
' 2>&1 || true)
assert_contains "$out" "not applicable to a local install" "preflight refuses local mode"

# Argument validation must come BEFORE the privilege gate, so these assertions
# hold whether or not the suite is running as root. CI runs unprivileged; the
# development box runs as root. An ordering that only passes on one of them is
# the bug this arrangement pins.
out=$(bash -c '
  source lib/service-migration.sh
  log() { :; }; warn() { :; }
  error() { echo "ERROR: $1"; exit 1; }
  LOCAL_MODE=false
  service_migration_preflight root /root engineering
' 2>&1 || true)
assert_contains "$out" "cannot be root" "preflight refuses root as target"

# Privilege gate itself, forced on regardless of who is running the suite.
out=$(bash -c '
  source lib/service-migration.sh
  log() { :; }; warn() { :; }
  error() { echo "ERROR: $1"; exit 1; }
  service_migration_effective_uid() { echo 1000; }
  LOCAL_MODE=false
  service_migration_preflight opencode /root engineering
' 2>&1 || true)
assert_contains "$out" "must run as root" "preflight refuses an unprivileged run"

# A target home that already holds runtime state means a previous attempt got
# partway. Merging two session databases corrupts both.
mkdir -p "$TMP/home/opencode/.kimaki"
out=$(bash -c '
  source lib/service-migration.sh
  log() { :; }; warn() { :; }
  error() { echo "ERROR: $1"; exit 1; }
  service_migration_effective_uid() { echo 0; }
  service_migration_target_home() { echo "'"$TMP"'/home/opencode"; }
  LOCAL_MODE=false
  service_migration_preflight opencode /root engineering
' 2>&1 || true)
assert_contains "$out" "already contains" "preflight refuses to merge runtime state"

echo ""
echo "service-migration: --non-root on a root install is refused"

# The #93 footgun. Reachability of the guard matters as much as its wording:
# upgrade.sh must consult the INSTALLED unit, not the flag-derived default,
# because --non-root suppresses identity adoption.
assert_contains "$(cat upgrade.sh)" "Use --migrate-non-root to move it properly" \
  "upgrade.sh refuses bare --non-root on a root install"
assert_contains "$(cat upgrade.sh)" 'INSTALLED_SERVICE_USER="$(service_migration_installed_user)"' \
  "upgrade.sh reads the installed identity independently of the forced flag"

# The migration must run before anything renders a unit or writes into the
# service home, and after UPDATED_ITEMS exists so it can report itself.
mig_line=$(grep -n 'service_migration_run' upgrade.sh | head -1 | cut -d: -f1)
items_line=$(grep -n '^UPDATED_ITEMS=()' upgrade.sh | head -1 | cut -d: -f1)
if [ -n "$mig_line" ] && [ -n "$items_line" ] && [ "$mig_line" -gt "$items_line" ]; then
  echo "  ok   migration runs after UPDATED_ITEMS is declared"
else
  echo "  FAIL migration at line ${mig_line:-?} must come after UPDATED_ITEMS at line ${items_line:-?}"
  FAILED=$((FAILED + 1))
fi

echo ""
echo "service-migration: AGENTS.md is composed as the service user"

# The generated text encodes the composing process's euid: data-machine and
# data-machine-code both append `--allow-root` to their WP-CLI examples when
# posix_geteuid() === 0. upgrade.sh runs under sudo, so composing as the caller
# writes an AGENTS.md telling a non-root agent to run `wp --allow-root` — a file
# that misdescribes the agent's own environment (#322). `--allow-root` is a
# no-op for a non-root caller so nothing breaks, which is exactly why this would
# otherwise go unnoticed.
assert_contains "$(cat upgrade.sh)" "wp_run_as_service_user datamachine memory compose AGENTS.md" \
  "upgrade.sh composes AGENTS.md as the service user"
assert_contains "$(cat lib/homeboy.sh)" "wp_run_as_service_user datamachine memory compose AGENTS.md" \
  "homeboy recompose also drops to the service user"

# Every EXECUTING compose call site must go through the helper, or the one that
# does not silently re-bakes --allow-root over the correct file. Dry-run echoes
# and comments are prose about the call, not the call — strip grep's
# `file:line:` prefix before testing for a leading `#`.
stray=$(grep -n 'datamachine memory compose AGENTS.md' upgrade.sh lib/*.sh \
  | grep -v 'wp_run_as_service_user' \
  | grep -v 'dry-run' \
  | sed 's/^[^:]*:[0-9]*: *//' \
  | grep -v '^#' || true)
if [ -z "$stray" ]; then
  echo "  ok   no compose call site bypasses the service-user helper"
else
  echo "  FAIL compose call site bypasses the service-user helper:"
  echo "$stray" | sed 's/^/         /'
  FAILED=$((FAILED + 1))
fi

# The helper must not pass --allow-root when it has dropped privileges: the
# whole point of that branch is that the invocation is not root.
helper=$(sed -n '/^wp_run_as_service_user()/,/^}/p' lib/wordpress.sh)
sudo_branch=$(printf '%s\n' "$helper" | sed -n '/sudo -n -H -u/p')
refute_contains "$sudo_branch" 'WP_ROOT_FLAG' "service-user branch omits --allow-root"
assert_contains "$helper" 'WP_ROOT_FLAG' "caller branch still passes the root flag"

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "service-migration: all assertions passed"
else
  echo "service-migration: $FAILED assertion(s) failed"
  exit 1
fi
