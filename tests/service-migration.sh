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

# And the inventories themselves must be clean under BOTH modes, which is
# the assertion that survives someone adding an entry to the lists later.
for mode in workspace owned; do
  inv="$(service_migration_inventory "$mode")"
  for bad in .ssh .secrets .pki .gnupg .aws .bash_history; do
    refute_contains "$inv" "$bad" "$mode inventory omits $bad"
  done
done

echo ""
echo "service-migration: source mode shapes the inventory"

eng="$(service_migration_inventory workspace)"
man="$(service_migration_inventory owned)"

# Runtime state is what the agent IS — required under every mode, or the
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
  inv="$(service_migration_inventory workspace)"
  assert_contains "$inv" "homeboy-modules" "extra path is carried"
  assert_contains "$inv" "go-sdk" "second extra path is carried"
  # And still absent from managed's runtime-only base set unless asked for.
  assert_contains "$(service_migration_inventory owned)" "homeboy-modules" \
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
echo "service-migration: refuses to migrate from inside the unit it stops"

# An agent driving its own upgrade runs inside the chat-bridge unit
# (0::/system.slice/kimaki.service). Stopping that unit kills the migration
# mid-move: state partly relocated, no unit rendered, nothing left running to
# finish or report. It must refuse, and it must be a refusal rather than a
# warning, because the process that would read the warning is the one that dies.
out=$(bash -c '
  source lib/service-migration.sh
  log() { :; }; warn() { :; }
  error() { echo "ERROR: $1"; exit 1; }
  service_migration_effective_uid() { echo 0; }
  service_migration_current_unit() { echo "kimaki.service"; }
  bridge_systemd_units() { echo "kimaki.service"; }
  LOCAL_MODE=false
  service_migration_preflight opencode /root engineering
' 2>&1 || true)
assert_contains "$out" "Refusing to migrate from inside" "refuses self-hosted migration"
assert_contains "$out" "systemd-run" "names a detached way to re-run it"

# ...and does NOT refuse when the caller is outside the service (an SSH shell,
# or systemd-run under its own transient unit).
out=$(bash -c '
  source lib/service-migration.sh
  log() { :; }; warn() { :; }
  error() { echo "ERROR: $1"; exit 1; }
  service_migration_effective_uid() { echo 0; }
  service_migration_current_unit() { echo ""; }
  bridge_systemd_units() { echo "kimaki.service"; }
  service_migration_target_home() { echo "'"$TMP"'/fresh-home"; }
  LOCAL_MODE=false
  service_migration_preflight opencode /root engineering && echo PREFLIGHT_OK
' 2>&1 || true)
assert_contains "$out" "PREFLIGHT_OK" "allows migration from outside the unit"

echo ""
echo "service-migration: state lands owned by the service user"

# Every level created on the way down must be chowned, not just the immediate
# parent: `mkdir -p ~/.local/share` as root creates BOTH root-owned, and
# chowning only `.local/share` leaves `.local` unwritable — which surfaces later
# as a permission error nowhere near this code.
MOVE=$TMP/move
mkdir -p "$MOVE/old/.local/share/opencode" "$MOVE/old/.kimaki" "$MOVE/new"
echo data >"$MOVE/old/.local/share/opencode/sessions.db"

MOVE_USER="daemon"
MOVE_GROUP="$(id -gn "$MOVE_USER" 2>/dev/null || echo daemon)"

if [ "$(id -u)" -eq 0 ]; then
  (
    log() { :; }; warn() { :; }; error() { echo "ERROR: $1"; exit 1; }
    run_cmd() { "$@"; }
    # shellcheck disable=SC1091
    source lib/service-migration.sh
    service_migration_move_path ".local/share/opencode" "$MOVE/old" "$MOVE/new" "$MOVE_USER"
    service_migration_move_path ".kimaki" "$MOVE/old" "$MOVE/new" "$MOVE_USER"
  ) >/dev/null 2>&1

  for p in ".local" ".local/share" ".local/share/opencode" ".kimaki"; do
    owner=$(stat -c '%U' "$MOVE/new/$p" 2>/dev/null || echo MISSING)
    assert_eq "$owner" "$MOVE_USER" "$p is owned by the service user"
  done
  assert_eq "$(stat -c '%U' "$MOVE/new/.local/share/opencode/sessions.db" 2>/dev/null || echo MISSING)" \
    "$MOVE_USER" "moved file contents are owned by the service user"
  # The source must be gone — a copy would leave the old identity's session
  # database live alongside the new one.
  if [ ! -e "$MOVE/old/.kimaki" ]; then
    echo "  ok   source path is moved, not copied"
  else
    echo "  FAIL source path still exists after migration"
    FAILED=$((FAILED + 1))
  fi
else
  echo "  skip ownership assertions (requires root)"
fi

# `chown user:user` assumes the primary group matches the account name. That
# holds for a useradd-created `opencode` and not for an existing account named
# via --migrate-user (`nobody` is in `nogroup` on Debian), where chown fails
# outright rather than degrading.
assert_eq "$(service_migration_user_group nobody)" "$(id -gn nobody)" \
  "primary group is read from the account, not assumed"
assert_eq "$(service_migration_user_group definitely-no-such-user-here)" \
  "definitely-no-such-user-here" "falls back to the user name when absent"

echo ""
echo "service-migration: ExecStartPre survives a root-owned package dir"

# bridges/kimaki/post-upgrade.sh runs as ExecStartPre, as the SERVICE user,
# under `set -euo pipefail`, with no `-` prefix on the unit directive — so any
# non-zero exit blocks the service from starting at all. It removes bundled
# skills from the npm package dir, which is root-owned (/usr/lib/node_modules,
# 0755) and which a non-root service user cannot unlink from.
#
# This predates the migration: it breaks any `--non-root` install, a shape
# setup.sh already supports. The migration is what makes it reachable. It also
# fails LATE — only once `npm update -g kimaki` has recreated a bundled skill is
# there anything to remove — so it would present as a service that mysteriously
# stops booting long after the migration looked successful.
assert_contains "$(cat bridges/kimaki/post-upgrade.sh)" "try_remove_package_path" \
  "package-dir removals go through the best-effort helper"

unguarded=$(grep -nE '^\s*rm -(rf|f) "\$(skill_dir|obsolete_plugin)"' bridges/kimaki/post-upgrade.sh || true)
if [ -z "$unguarded" ]; then
  echo "  ok   no unguarded rm on a package path remains"
else
  echo "  FAIL unguarded rm would abort ExecStartPre under set -e:"
  echo "$unguarded" | sed 's/^/         /'
  FAILED=$((FAILED + 1))
fi

# Behavioural: the helper must return 0 and keep going when the path cannot be
# removed. An assertion on the text alone would not catch a helper that warns
# and then still fails.
if [ "$(id -u)" -eq 0 ]; then
  EP=$TMP/execstartpre
  mkdir -p "$EP/skills/upgrade-wp-coding-agents"
  echo x >"$EP/skills/upgrade-wp-coding-agents/SKILL.md"
  chmod -R go+rX "$TMP" 2>/dev/null || true
  helper_src=$(sed -n '/^try_remove_package_path() {/,/^}/p' bridges/kimaki/post-upgrade.sh)
  out=$(su -s /bin/bash nobody -c "bash -c '
set -euo pipefail
skills_removed=0; skills_unremovable=0
$helper_src
try_remove_package_path \"$EP/skills/upgrade-wp-coding-agents\" \"duplicate skill\"
echo REACHED_END
'" 2>&1 || true)
  assert_contains "$out" "REACHED_END" "script continues past an unremovable path"
  assert_contains "$out" "WARNING" "and warns about it"
  if [ -d "$EP/skills/upgrade-wp-coding-agents" ]; then
    echo "  ok   the unremovable path is left in place"
  else
    echo "  FAIL path was removed in a test that should not have been able to"
    FAILED=$((FAILED + 1))
  fi
else
  echo "  skip ExecStartPre behavioural check (requires root)"
fi

echo ""
echo "service-migration: AGENTS.md is composed as the service user"

# The generated text encodes the composing process's euid: data-machine and
# generated Data Machine guidance appends `--allow-root` to WP-CLI examples when
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
  | grep -v '^echo ' \
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

echo ""
echo "service-migration: the unit's environment follows the identity"

# Found by migrating h44lacrosse.com and checking the rendered unit BEFORE
# starting anything. The migration produced User=opencode alongside
# Environment=HOME=/root and KIMAKI_DATA_DIR=/root/.kimaki: the merge keeps the
# installed unit's value for any key the template also sets, deliberately, so
# operator edits survive an upgrade — but identity-derived values are not
# operator edits. Starting that unit runs the agent as a user that cannot read
# either path (/root is 0700), so it comes up with no session database and no
# runtime state.
#
# Same defect as #204 from the other direction: there the User flipped silently
# while state stayed put; here the User moved and the environment stayed put.

# shellcheck disable=SC1091
source bridges/_dispatch.sh 2>/dev/null || true

INSTALLED_ENV='Environment=HOME=/root
Environment=PATH=/root/.kimaki/bin:/root/.cargo/bin:/usr/bin:/bin
Environment=KIMAKI_DATA_DIR=/root/.kimaki
Environment=BUN_INSTALL=/root/.bun
Environment=OPERATOR_CUSTOM=keep-me'

TEMPLATE_ENV='Environment=HOME=/home/opencode
Environment=PATH=/home/opencode/.kimaki/bin:/usr/bin:/bin
Environment=KIMAKI_DATA_DIR=/home/opencode/.kimaki'

# Without a migration in flight nothing is invalidated: an ordinary upgrade must
# not rewrite an operator's environment.
MERGED_NORMAL=$(SERVICE_MIGRATION_PREVIOUS_HOME="" _merge_systemd_env_lines "$INSTALLED_ENV" "$TEMPLATE_ENV")
assert_contains "$MERGED_NORMAL" "Environment=HOME=/root" \
  "an ordinary upgrade keeps the installed HOME"
assert_contains "$MERGED_NORMAL" "OPERATOR_CUSTOM=keep-me" \
  "an ordinary upgrade keeps operator additions"

# Mid-migration, every value built from the old home is replaced.
MERGED_MIG=$(SERVICE_MIGRATION_PREVIOUS_HOME="/root" _merge_systemd_env_lines "$INSTALLED_ENV" "$TEMPLATE_ENV")
assert_contains "$MERGED_MIG" "Environment=HOME=/home/opencode" "HOME follows the new identity"
assert_contains "$MERGED_MIG" "KIMAKI_DATA_DIR=/home/opencode/.kimaki" "the data dir follows"
refute_contains "$MERGED_MIG" "HOME=/root" "the old HOME is gone"
refute_contains "$MERGED_MIG" "/root/.kimaki" "no value still points into the old home"

# PATH is the one a key-name list would have missed: it is not obviously an
# identity value, and a stale one leaves the agent unable to reach its binaries.
refute_contains "$MERGED_MIG" "/root/.cargo/bin" "a stale PATH entry is dropped"
refute_contains "$MERGED_MIG" "BUN_INSTALL=/root/.bun" "so is an unrelated tool var"

# Operator additions that say nothing about identity still survive a migration.
assert_contains "$MERGED_MIG" "OPERATOR_CUSTOM=keep-me" \
  "a migration preserves operator additions"

# The migration must publish the old home, or the filter above never engages.
assert_contains "$(sed -n '/^service_migration_run/,/^}/p' lib/service-migration.sh)" \
  'SERVICE_MIGRATION_PREVIOUS_HOME="$old_home"' \
  "service_migration_run publishes the previous home"

echo ""
echo "service-migration: wp-config hardening is not optional"

# The reclaim chmods the whole site g+w and then hardens wp-config back. That
# harden lived in lib/infrastructure.sh, which setup.sh sources and upgrade.sh
# does not, behind a `declare -F` guard — so on an upgrade the function did not
# exist, the guard silently skipped it, and h44lacrosse.com came out of the
# migration with its database credentials group-writable (660, not 640).
#
# A guard around a function you REQUIRE converts a missing dependency into
# silent breakage.
reclaim=$(sed -n '/^service_migration_reclaim_site/,/^}/p' lib/service-migration.sh)
refute_contains "$reclaim" "declare -F harden_wp_config_permissions" \
  "hardening is not behind a declare -F guard"
assert_contains "$reclaim" "harden_wp_config_permissions" "hardening still happens"

# It must be defined in a lib upgrade.sh actually sources.
upgrade_libs=$(grep -o 'for lib in [a-z0-9 -]*' upgrade.sh)
defined_in=$(grep -rl '^harden_wp_config_permissions()' lib/ | head -1 | xargs -r basename | sed 's/\.sh$//')
case "$upgrade_libs" in
  *"$defined_in"*) echo "  ok   defined in '$defined_in', which upgrade.sh sources" ;;
  *) echo "  FAIL defined in '$defined_in', which upgrade.sh does NOT source"; FAILED=$((FAILED + 1)) ;;
esac

# And it must run AFTER the blanket g+w, or the g+w undoes it.
chmod_line=$(printf '%s\n' "$reclaim" | grep -n 'chmod -R g+w' | head -1 | cut -d: -f1)
harden_line=$(printf '%s\n' "$reclaim" | grep -n '^  harden_wp_config_permissions' | head -1 | cut -d: -f1)
if [ -n "$chmod_line" ] && [ -n "$harden_line" ] && [ "$harden_line" -gt "$chmod_line" ]; then
  echo "  ok   hardening runs after the blanket g+w"
else
  echo "  FAIL ordering wrong (chmod=${chmod_line:-?} harden=${harden_line:-?})"
  FAILED=$((FAILED + 1))
fi
