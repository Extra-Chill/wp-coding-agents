#!/bin/bash
# lib/service-migration.sh — in-place migration of an installed agent from the
# root service identity to a dedicated non-root service user.
#
# WHY THIS EXISTS
#
# `lib/detect.sh` has always been able to install non-root (`SERVICE_USER=opencode`,
# `create_service_user`, `User=opencode` in every unit). What has never existed is
# a way to move an install that is ALREADY running as root onto that path. #93
# describes the consequence — root-owned files cascading through the site until
# WordPress auto-update fails — and closes with "existing installs running as root
# can migrate in-place without reinstalling everything". This module is that.
#
# Before this file, `./upgrade.sh --non-root` on a root install was a footgun. It
# set SERVICE_USER_FORCED=true (skipping identity adoption), re-rendered every unit
# with `User=opencode`, and did nothing else: it never created the user, and
# because KIMAKI_DATA_DIR is derived from the service home, it silently repointed
# the agent at an empty `/home/opencode/.kimaki` while the live session database,
# runtime auth, and installed toolchains stayed behind in `/root`. The service came
# back up amnesiac, or not at all.
#
# THE INVENTORY IS THE CAPABILITY BOUNDARY
#
# The important property of this migration is not the chown. It is that the new
# service home starts EMPTY and is filled only from an explicit allowlist. `/root`
# is mode 0700, so every path NOT in the inventory becomes unreachable to the agent
# the moment the identity changes. That is the point.
#
# On the install this was written against, `/root` held `.ssh` (with private keys
# to other machines in the fleet), `.secrets`, per-site database passwords, and API
# tokens — all reachable by an agent running as root, none of them anything the
# agent needs. Migrating is what takes them away. So the inventory below is not a
# convenience list of "stuff to copy", it is a claim about what the agent is
# entitled to, and it is deliberately enumerated rather than globbed (#318: a glob
# that says "the agent's files" will, on somebody else's install, mean something
# nobody intended).
#
# The inventory is mode-aware, which makes it the file-axis counterpart to the
# capability table in #327:
#
#   owned         runtime state only. No dev toolchain, no forge credentials —
#                 an owned-mode agent has no git and no GitHub in its world at all,
#                 so migrating them would hand over reach it has no use for.
#   workspace     runtime state plus the dev toolchain and forge auth, because
#                 that mode's whole job is workspace/git/GitHub work.
#
# Neither mode migrates SSH keys, secret stores, or shell history. There is no
# flag to opt into that. An agent that needs to reach another host should be given
# a scoped credential deliberately, not inherit the operator's.
#
# WHAT THIS MODULE DOES NOT DO
#
# It does not render systemd units. Once it has moved state and set SERVICE_USER /
# SERVICE_HOME / KIMAKI_DATA_DIR, the existing upgrade phases re-render units from
# those variables the same way they always have. Duplicating unit rendering here
# would create a second source of truth for the thing #204 already fixed.
#
# Public surface:
#   service_migration_runtime_paths           # newline-separated, HOME-relative
#   service_migration_toolchain_paths         # newline-separated, HOME-relative
#   service_migration_inventory <mode>     # the two above, per mode
#   service_migration_excluded_paths          # documented never-migrate list
#   service_migration_is_excluded <rel>       # 0 = must never be migrated
#   service_migration_preflight               # fails closed, changes nothing
#   service_migration_estimate_bytes <home> <mode>
#   service_migration_run                     # the migration itself
#
# Honors DRY_RUN (logs intent, makes no changes).

# Marker recording that an install has completed the migration, so a later
# upgrade can tell "non-root because it was installed that way" apart from
# "non-root because it was migrated" when reporting state to the operator.
SERVICE_MIGRATION_OPTION="wp_coding_agents_service_identity_migrated"

# Default target identity. Matches lib/detect.sh's non-root branch; changing one
# without the other would strand state under a home nothing points at.
SERVICE_MIGRATION_DEFAULT_USER="opencode"

# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------

# Runtime state: the agent's own brain. Without these the migrated service is
# amnesiac — no sessions, no runtime auth, no CLI state. Migrated under every
# mode because they are what "the agent" IS.
service_migration_runtime_paths() {
  cat <<'EOF'
.kimaki
.opencode
.config/opencode
.local/share/opencode
.local/state/opencode
.wp-cli
EOF
}

# Dev toolchain and forge credentials. Workspace mode only: these exist to
# serve workspace/git/GitHub work, which is precisely what owned mode does
# not do. Handing an owned-mode agent GitHub auth would widen its reach for no
# capability it is ever asked to exercise.
service_migration_toolchain_paths() {
  cat <<'EOF'
.cargo
.rustup
.bun
.npm
.local/share/pnpm
.claude
.claude.json
.homeboy
.config/homeboy
.local/share/homeboy
.config/gh
.gitconfig
.composer
.config/composer
.local/share/composer
.config/go
go
EOF
}

# Paths that must never migrate, whatever the mode. Enumerated so the
# exclusion is reviewable and testable rather than implied by absence — an
# inventory that merely forgets `.ssh` is one careless addition away from
# shipping it.
#
# These stay owned by root under a 0700 home, which is what removes them from
# the agent's reach. That is the migration's security payload.
service_migration_excluded_paths() {
  cat <<'EOF'
.ssh
.secrets
.pki
.gnupg
.aws
.bash_history
.mysql_history
EOF
}

# 0 when the given HOME-relative path must never be migrated.
#
# Matches the explicit list above, plus two shape-based rules that catch the
# operator-specific secrets this was written against (`.h44-secrets`,
# `sweatpants-api-token.txt`, `opencode-auth-backup.json`). Those particular
# names mean nothing on another install, so they are matched by shape — anything
# announcing itself as a secret, credential, token, or password — rather than
# named (#320: never assert install-specific facts in shipped code).
service_migration_is_excluded() {
  local rel="$1" excluded
  while IFS= read -r excluded; do
    [ -n "$excluded" ] || continue
    [ "$rel" = "$excluded" ] && return 0
    case "$rel" in "$excluded"/*) return 0 ;; esac
  done <<<"$(service_migration_excluded_paths)"

  # Deliberately broad. These patterns are asymmetric in cost: a false positive
  # means the operator moves one directory by hand, a false negative means the
  # agent is handed a credential and the migration still reports success. `*pass*`
  # rather than `*password*` because the install this was written against had a
  # database password in a file called `.h44-target-dbpass`, which the narrower
  # pattern sailed straight past.
  case "$rel" in
    *secret*|*credential*|*token*|*pass*|*.pem|*.key|*auth-backup*)
      return 0 ;;
  esac
  return 1
}

# Operator-declared extra paths, newline-separated, HOME-relative. Set by
# --migrate-extra.
#
# The shipped inventory can only name paths that mean the same thing on every
# install (#320). Real machines accumulate install-specific state next to it —
# the box this was developed on had `homeboy-modules`, `go-sdk`, and a `bin` on
# the service PATH, none of which a generic list can responsibly guess at. This
# is where the operator names those, and it is still filtered through the
# exclusion rules: the escape hatch does not become the way SSH keys travel.
SERVICE_MIGRATION_EXTRA_PATHS="${SERVICE_MIGRATION_EXTRA_PATHS:-}"

# The inventory for a mode, as newline-separated HOME-relative paths.
# Excluded paths are filtered unconditionally, so neither a future edit to the
# lists above nor an operator's --migrate-extra can leak a credential.
service_migration_inventory() {
  local mode="${1:-workspace}" rel
  # Accept the pre-rename names. A caller passing `managed` and silently
  # getting the workspace inventory would migrate a dev toolchain and GitHub
  # credentials onto an owned-mode agent, which is the one thing the split
  # exists to prevent.
  case "$mode" in
    managed)     mode="owned" ;;
    engineering) mode="workspace" ;;
  esac

  {
    service_migration_runtime_paths
    [ "$mode" != "owned" ] && service_migration_toolchain_paths
    [ -n "$SERVICE_MIGRATION_EXTRA_PATHS" ] && printf '%s\n' "$SERVICE_MIGRATION_EXTRA_PATHS"
  } | while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    service_migration_is_excluded "$rel" && continue
    echo "$rel"
  done
}

# Reject an operator-supplied extra path outright rather than silently dropping
# it. Someone who types `--migrate-extra .ssh` has a reason in mind and needs to
# be told it will not happen, not left to discover the agent cannot reach its
# keys after the service has already moved.
service_migration_add_extra_path() {
  local rel="$1"

  case "$rel" in
    /*|*..*)
      error "--migrate-extra takes a path relative to the service home, not '$rel'." ;;
  esac

  if service_migration_is_excluded "$rel"; then
    error "Refusing --migrate-extra '$rel': it matches the credential exclusion list. Moving SSH keys or secret stores onto the service user would undo the reason for migrating. Move it by hand if you are certain."
  fi

  if [ -z "$SERVICE_MIGRATION_EXTRA_PATHS" ]; then
    SERVICE_MIGRATION_EXTRA_PATHS="$rel"
  else
    SERVICE_MIGRATION_EXTRA_PATHS="$SERVICE_MIGRATION_EXTRA_PATHS
$rel"
  fi
}

# Total bytes the inventory occupies under a given home. Used by preflight to
# refuse a migration that would fill the disk partway through.
service_migration_estimate_bytes() {
  local home="$1" mode="${2:-workspace}" rel total=0 sz
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -e "$home/$rel" ] || continue
    sz=$(du -sb "$home/$rel" 2>/dev/null | cut -f1)
    [ -n "$sz" ] && total=$((total + sz))
  done <<<"$(service_migration_inventory "$mode")"
  echo "$total"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# The uid the migration would run as. A function rather than a bare $EUID read
# so tests can exercise the checks that come after the privilege gate without
# being root — the same seam SYSTEMD_UNIT_DIR provides for unit discovery.
service_migration_effective_uid() {
  echo "${EUID:-$(id -u)}"
}

# Fails closed on anything that would leave a half-migrated install. Changes
# nothing, so it is safe to call before confirming with the operator.
#
# Argument validation comes before the privilege gate on purpose: a mistyped
# --migrate-user should say so, not send the operator off to re-run under sudo
# only to be told the flag was wrong all along.
#
# Args: <target_user> <old_home> <mode>
service_migration_preflight() {
  local target_user="$1" old_home="$2" mode="${3:-workspace}"

  if [ "${LOCAL_MODE:-false}" = true ]; then
    error "Service identity migration is not applicable to a local install (no systemd, no service user)."
  fi

  if [ "$target_user" = "root" ]; then
    error "Migration target user cannot be root — that is the identity being migrated away from."
  fi

  if [ -z "$target_user" ]; then
    error "Migration target user cannot be empty."
  fi

  if [ "$(service_migration_effective_uid)" -ne 0 ]; then
    error "Service identity migration must run as root (sudo ./upgrade.sh --migrate-non-root)."
  fi

  if [ ! -d "$old_home" ]; then
    error "Current service home '$old_home' does not exist; refusing to migrate from a home that was never used."
  fi

  # An agent that drives this from inside its own chat bridge is sitting in the
  # unit the migration stops. `systemctl stop kimaki.service` would kill the
  # migration mid-move, with 8 GiB of state partly relocated, no unit rendered,
  # and nothing left running to finish or report. Recovery would be by hand, on
  # a box whose agent is now gone.
  #
  # It has to be a refusal rather than a warning, because the process that would
  # read the warning is the one that disappears.
  local current_unit unit
  current_unit=$(service_migration_current_unit)
  if [ -n "$current_unit" ]; then
    while IFS= read -r unit; do
      [ -n "$unit" ] || continue
      if [ "$unit" = "$current_unit" ]; then
        error "Refusing to migrate from inside '$current_unit' — this migration stops that unit, which would kill this process partway through. Re-run it detached from the service, e.g.: systemd-run --unit=wpca-migrate --same-dir --wait $0 --migrate-non-root"
      fi
    done <<<"$(service_migration_units)"
  fi

  # A target home that already holds runtime state means a previous attempt got
  # partway, or the user is shared with another install. Merging two runtime
  # states silently corrupts session databases, so stop and let a human look.
  local new_home rel
  new_home=$(service_migration_target_home "$target_user")
  if [ -d "$new_home" ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      if [ -e "$new_home/$rel" ]; then
        error "Target home '$new_home' already contains '$rel'. Refusing to merge runtime state — inspect and remove it, or choose another target user."
      fi
    done <<<"$(service_migration_inventory "$mode")"
  fi

  # Same-filesystem moves are renames and need no headroom; a cross-filesystem
  # move needs the full inventory size free at the destination.
  local old_fs new_fs need avail
  old_fs=$(df -P "$old_home" 2>/dev/null | awk 'NR==2 {print $1}')
  new_fs=$(df -P "$(dirname "$new_home")" 2>/dev/null | awk 'NR==2 {print $1}')
  if [ -n "$old_fs" ] && [ "$old_fs" != "$new_fs" ]; then
    need=$(service_migration_estimate_bytes "$old_home" "$mode")
    avail=$(df -PB1 "$(dirname "$new_home")" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$avail" ] && [ "$need" -gt 0 ] && [ "$avail" -lt "$need" ]; then
      error "Not enough space to migrate: need $((need / 1024 / 1024)) MiB at '$new_home', $((avail / 1024 / 1024)) MiB available."
    fi
  fi

  return 0
}

# The systemd unit this process is running inside, empty when it is not under
# one. An agent driving its own upgrade is inside the very unit the migration
# stops (`0::/system.slice/kimaki.service`), so this is how it finds out.
service_migration_current_unit() {
  local line
  [ -r /proc/self/cgroup ] || return 0
  line=$(awk -F: '$1 == "0" {print $3}' /proc/self/cgroup 2>/dev/null | head -1)
  case "$line" in
    */*.service) echo "${line##*/}" ;;
    *) : ;;
  esac
}

# The units the migration would stop, newline-separated.
service_migration_units() {
  local unit units=""
  if declare -F bridge_systemd_units >/dev/null 2>&1; then
    units="$(bridge_systemd_units)"
  fi
  if declare -F datamachine_worker_systemd_units >/dev/null 2>&1; then
    units="$units $(datamachine_worker_systemd_units)"
  fi
  for unit in $units; do
    [ -n "$unit" ] && echo "$unit"
  done
}

# Read the identity the install is CURRENTLY running under, straight from the
# installed units. Read-only counterpart to adopt_service_identity_from_units:
# --non-root / --migrate-non-root set SERVICE_USER_FORCED=true, which suppresses
# adoption, so the migration path needs its own way to see what it is migrating
# FROM. Echoes nothing when no unit is installed.
service_migration_installed_user() {
  local unit_dir="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
  local unit units="" unit_user
  if declare -F bridge_systemd_units >/dev/null 2>&1; then
    units="$(bridge_systemd_units)"
  fi
  if declare -F datamachine_worker_systemd_units >/dev/null 2>&1; then
    units="$units $(datamachine_worker_systemd_units)"
  fi
  for unit in $units; do
    [ -f "$unit_dir/$unit" ] || continue
    if declare -F _systemd_unit_user >/dev/null 2>&1; then
      unit_user=$(_systemd_unit_user "$unit_dir/$unit") || continue
    else
      unit_user=$(awk -F= '/^User=/ {print $2; exit}' "$unit_dir/$unit")
    fi
    [ -n "$unit_user" ] && { echo "$unit_user"; return 0; }
  done
  return 0
}

# Resolve the home directory for a target user — the account's real home when it
# already exists, the useradd default when it does not.
service_migration_target_home() {
  local user="$1" home
  home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
  [ -n "$home" ] && { echo "$home"; return 0; }
  echo "/home/$user"
}

# ---------------------------------------------------------------------------
# Migration
# ---------------------------------------------------------------------------

# Stop every unit that runs under the old identity before touching its state.
# Kimaki's session store is SQLite in WAL mode; moving it under a live writer
# corrupts it.
service_migration_stop_units() {
  local unit
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    [ -f "/etc/systemd/system/$unit" ] || continue
    case "$unit" in
      *.timer|*.service) run_cmd systemctl stop "$unit" ;;
    esac
  done <<<"$(service_migration_units)"
}

# The account's primary group. `useradd -m` creates a matching group for a new
# account, but --migrate-user may name an existing one whose primary group is
# something else entirely (`nobody` is in `nogroup` on Debian), and
# `chown user:user` fails outright there rather than degrading.
service_migration_user_group() {
  local user="$1" group
  group=$(id -gn "$user" 2>/dev/null) || group=""
  [ -n "$group" ] && { echo "$group"; return 0; }
  echo "$user"
}

# Move one inventory entry, preserving the parent structure (`.config/opencode`
# has to land under a `.config` that exists and is owned by the service user).
#
# Every level created on the way down is chowned, not just the immediate parent.
# `mkdir -p ~/.local/share` run as root creates BOTH levels root-owned; chowning
# only `.local/share` leaves `.local` itself unwritable by the service user, so
# anything that later wants `~/.local/bin` or `~/.local/state` fails with a
# permission error far away from here.
service_migration_move_path() {
  local rel="$1" old_home="$2" new_home="$3" user="$4"
  local src="$old_home/$rel" dest="$new_home/$rel"

  [ -e "$src" ] || return 0

  local group parent
  group=$(service_migration_user_group "$user")
  parent=$(dirname "$dest")
  run_cmd mkdir -p "$parent"

  # Walk new_home -> parent, chowning each component.
  local walk="$new_home" component
  run_cmd chown "$user:$group" "$walk"
  while IFS= read -r component; do
    # dirname of a top-level entry like `.kimaki` is `.` — nothing to walk.
    [ -n "$component" ] && [ "$component" != "." ] || continue
    walk="$walk/$component"
    [ "$walk" = "$dest" ] && break
    run_cmd chown "$user:$group" "$walk"
  done <<<"$(dirname "$rel" | tr '/' '\n')"

  run_cmd mv "$src" "$dest"
  run_cmd chown -R "$user:$group" "$dest"
}

# Hand the WordPress install back to www-data with group write, and put the
# service user in that group. This is the same end state `setup_service_permissions`
# produces for a fresh non-root install — the difference is only that here it has
# to undo existing root ownership rather than establish it from nothing.
service_migration_reclaim_site() {
  local user="$1" site_path="$2"

  [ -n "$site_path" ] || return 0
  [ -d "$site_path" ] || return 0

  run_cmd chown -R www-data:www-data "$site_path"
  run_cmd chmod -R g+w "$site_path"
  if declare -F harden_wp_config_permissions >/dev/null 2>&1; then
    harden_wp_config_permissions "$site_path"
  fi
}

# The agent's code workspace, when one exists (workspace mode only —
# owned-mode installs have no workspace by definition).
service_migration_reclaim_workspace() {
  local user="$1" workspace="$2"

  [ -n "$workspace" ] || return 0
  [ -d "$workspace" ] || return 0

  local group
  group=$(service_migration_user_group "$user")
  run_cmd chown -R "$user:$group" "$workspace"
}

# Run the migration. Assumes service_migration_preflight has already passed.
#
# Args: <target_user> <old_home> <mode>
#
# On success, sets SERVICE_USER / SERVICE_HOME / KIMAKI_DATA_DIR / RUN_AS_ROOT /
# SERVICE_USER_FORCED for the caller so the normal upgrade phases re-render every
# unit against the new identity.
service_migration_run() {
  local target_user="$1" old_home="$2" mode="${3:-workspace}"
  local new_home rel

  new_home=$(service_migration_target_home "$target_user")

  log "Migrating service identity: root -> $target_user"
  log "  State home:  $old_home -> $new_home"
  log "  Source mode: $mode"

  if ! id -u "$target_user" >/dev/null 2>&1 || [ "${DRY_RUN:-false}" = true ]; then
    log "  Creating service user '$target_user'..."
    run_cmd useradd -m -s /bin/bash -G www-data "$target_user"
  else
    run_cmd usermod -a -G www-data "$target_user"
  fi

  log "  Stopping services under the old identity..."
  service_migration_stop_units

  log "  Moving agent state..."
  local target_group
  target_group=$(service_migration_user_group "$target_user")
  run_cmd mkdir -p "$new_home"
  run_cmd chown "$target_user:$target_group" "$new_home"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -e "$old_home/$rel" ] || [ "${DRY_RUN:-false}" = true ]; then
      log "    $rel"
      service_migration_move_path "$rel" "$old_home" "$new_home" "$target_user"
    fi
  done <<<"$(service_migration_inventory "$mode")"

  log "  Reclaiming WordPress file ownership..."
  service_migration_reclaim_site "$target_user" "${SITE_PATH:-}"

  if [ "$mode" != "owned" ]; then
    log "  Reclaiming code workspace..."
    service_migration_reclaim_workspace "$target_user" "${DM_WORKSPACE_DIR:-}"
  fi

  # Re-point the caller's identity variables. Everything downstream — unit
  # rendering, bridge config, data dir creation — derives from these.
  SERVICE_USER="$target_user"
  SERVICE_HOME="$new_home"
  RUN_AS_ROOT=false
  SERVICE_USER_FORCED=true
  if [ "${KIMAKI_DATA_DIR_EXPLICIT:-false}" != true ]; then
    KIMAKI_DATA_DIR="$new_home/.kimaki"
  fi

  log "Service identity migration complete: User=$SERVICE_USER, HOME=$SERVICE_HOME"
  warn "Credentials left behind in $old_home (SSH keys, secret stores) are now"
  warn "OUT of the agent's reach. That is intentional. If the agent legitimately"
  warn "needed one of them, issue it a scoped credential under $new_home instead"
  warn "of moving the operator's."
  # upgrade.sh does not restart services; it prints a restart hint at the end.
  # That is fine for an ordinary upgrade, where the units were never stopped —
  # but this migration DID stop them, so say so plainly rather than let the
  # operator infer it from a hint that looks routine.
  warn "Services were STOPPED for the migration and have not been restarted."
  warn "Start them once you have checked the rendered units (see the restart"
  warn "hint at the end of this run)."

  return 0
}
