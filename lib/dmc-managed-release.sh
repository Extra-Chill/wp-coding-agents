#!/bin/bash
# Official release updater for copied Data Machine Code deployments.

DMC_MANAGED_RELEASE_REPO="${DMC_MANAGED_RELEASE_REPO:-Extra-Chill/data-machine-code}"
DMC_MANAGED_RELEASE_API="${DMC_MANAGED_RELEASE_API:-https://api.github.com/repos/${DMC_MANAGED_RELEASE_REPO}/releases/latest}"

_dmc_managed_release_phase() {
  local phase="$1"
  shift
  if declare -F plugin_update_run_phase >/dev/null 2>&1 && [ "${PLUGIN_UPDATE_ACTIVE:-false}" = true ]; then
    plugin_update_run_phase data-machine-code "$phase" "$@"
  else
    PLUGIN_PHASE_OUTPUT="$("$@")"
  fi
}

_dmc_managed_release_abort() {
  local message="$1" status="${2:-1}"
  warn "$message"
  if [ "${PLUGIN_UPDATE_ACTIVE:-false}" = true ]; then
    return "$status"
  fi
  return 0
}

dmc_managed_release_plugin_dir() {
  printf '%s/wp-content/plugins/data-machine-code' "$SITE_PATH"
}

dmc_managed_release_header_version() {
  local file="$1/data-machine-code.php"
  [ -f "$file" ] || return 1
  grep -m1 -E '^[[:space:]]*\*?[[:space:]]*Version:' "$file" | sed -E 's/.*Version:[[:space:]]*([^[:space:]]+).*/\1/'
}

dmc_managed_release_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Print a tab-separated release tuple: version, archive URL, archive name,
# evidence type, expected digest or checksum URL.
dmc_managed_release_resolve() {
  local release_json="$1"
  DMC_RELEASE_JSON="$release_json" DMC_RELEASE_ASSET="${DMC_MANAGED_RELEASE_ASSET:-}" python3 <<'PY'
import json
import os
import re
import sys

data = json.loads(os.environ['DMC_RELEASE_JSON'])
tag = str(data.get('tag_name', ''))
if not __import__('re').fullmatch(r'v?\d+\.\d+(?:\.\d+){0,2}', tag):
    raise SystemExit('release tag must be a stable semantic version')
version = tag.lstrip('v')
assets = data.get('assets', [])
requested = os.environ['DMC_RELEASE_ASSET']
archives = [asset for asset in assets if str(asset.get('name', '')).endswith('.zip')]
archive = next((asset for asset in archives if asset.get('name') == requested), None) if requested else None
if archive is None and len(archives) == 1:
    archive = archives[0]
if archive is None:
    raise SystemExit('release must publish exactly one ZIP asset (or set DMC_MANAGED_RELEASE_ASSET)')
name = archive.get('name')
archive_url = archive.get('browser_download_url')
if not isinstance(name, str) or re.search(r'[\t\r\n]', name):
    raise SystemExit('release ZIP asset name is invalid')
if not isinstance(archive_url, str) or not re.fullmatch(r'https://[^\t\r\n]+', archive_url):
    raise SystemExit('release ZIP download URL is invalid')
digest = archive.get('digest')
if digest is not None:
    if not re.fullmatch(r'sha256:[0-9a-fA-F]{64}', str(digest)):
        raise SystemExit('release ZIP digest must be sha256 followed by 64 hexadecimal characters')
    print('\t'.join((version, archive_url, name, 'github_digest', str(digest)[7:].lower())))
    raise SystemExit(0)
checksums = [asset for asset in assets if str(asset.get('name', '')).lower() in (name.lower() + '.sha256', name.lower() + '.sha256sum', 'sha256sums', 'sha256sums.txt')]
if len(checksums) != 1:
    raise SystemExit('release must publish one SHA-256 checksum asset for the ZIP')
checksum_url = checksums[0].get('browser_download_url')
if not isinstance(checksum_url, str) or not re.fullmatch(r'https://[^\t\r\n]+', checksum_url):
    raise SystemExit('release checksum download URL is invalid')
print('\t'.join((version, archive_url, name, 'checksum_sidecar', checksum_url)))
PY
}

dmc_managed_release_resolve_environment() {
  dmc_managed_release_resolve "${DMC_RELEASE_JSON:-}"
}

dmc_managed_release_expected_sha256() {
  local checksum_file="$1" archive_name="$2"
  awk -v name="$archive_name" 'tolower($NF) == tolower(name) || NF == 1 { print $1; exit }' "$checksum_file" | tr '[:upper:]' '[:lower:]'
}

dmc_managed_release_provenance_file() {
  printf '%s/.wp-coding-agents-release-current/.wp-coding-agents-managed-release.json' "$(dmc_managed_release_plugin_dir)"
}

dmc_managed_release_active() {
  wp_cmd plugin is-active data-machine-code --skip-plugins >/dev/null 2>&1
}

dmc_managed_release_release_root() {
  printf '%s/.wp-coding-agents-releases' "$(dmc_managed_release_plugin_dir)"
}

dmc_managed_release_pointer_matches() {
  local plugin_dir="$1" version="$2" evidence_type="$3" evidence="$4"
  local current="$plugin_dir/.wp-coding-agents-release-current" provenance="$plugin_dir/.wp-coding-agents-release-current/.wp-coding-agents-managed-release.json"
  [ "$(dmc_managed_release_header_version "$current" 2>/dev/null || true)" = "$version" ] || return 1
  [ -f "$provenance" ] || return 1
  grep -Fq "\"repository\":\"$DMC_MANAGED_RELEASE_REPO\"" "$provenance" || return 1
  grep -Fq "\"version\":\"$version\"" "$provenance" || return 1
  [ "$evidence_type" != github_digest ] || grep -Fq "\"sha256\":\"$evidence\"" "$provenance"
}

dmc_managed_release_switch_pointer() {
  local plugin_dir="$1" release_dir="$2"
  local current="$plugin_dir/.wp-coding-agents-release-current" previous="$plugin_dir/.wp-coding-agents-release-previous" next="$plugin_dir/.wp-coding-agents-release-next"
  rm -f "$next"
  ln -s ".wp-coding-agents-releases/$(basename "$release_dir")" "$next" || return 1
  rm -f "$previous"
  [ ! -e "$current" ] || mv "$current" "$previous" || { rm -f "$next"; return 1; }
  mv "$next" "$current" || { dmc_managed_release_recover "$plugin_dir" || true; return 1; }
}

# Restore a complete prior release after an interrupted symlink switch. The
# root loader also uses this fallback, so DMC remains loadable before recovery.
dmc_managed_release_recover() {
  local plugin_dir="$1" releases current previous
  releases="$plugin_dir/.wp-coding-agents-releases"
  current="$plugin_dir/.wp-coding-agents-release-current"
  previous="$plugin_dir/.wp-coding-agents-release-previous"
  [ -e "$current/data-machine-code.php" ] || [ -e "$previous/data-machine-code.php" ] || return 0
  if [ ! -e "$current/data-machine-code.php" ] && [ -e "$previous/data-machine-code.php" ]; then
    mv "$previous" "$current" || return 1
    log "Recovered Data Machine Code release pointer after an interrupted update"
  fi
}

dmc_managed_release_loader() {
  local version="$1"
  cat <<PHP
<?php
/**
 * Plugin Name: Data Machine Code
 * Version: $version
 */

\$root = __DIR__;
\$current = \$root . '/.wp-coding-agents-release-current/data-machine-code.php';
\$previous = \$root . '/.wp-coding-agents-release-previous/data-machine-code.php';
if ( is_readable( \$current ) ) {
	require \$current;
} elseif ( is_readable( \$previous ) ) {
	require \$previous;
}
PHP
}

dmc_managed_release_status() {
  local plugin_dir current
  plugin_dir="$(dmc_managed_release_plugin_dir)"
  current="$(dmc_managed_release_header_version "$plugin_dir" 2>/dev/null || true)"
  if [ ! -d "$plugin_dir" ] || [ -d "$plugin_dir/.git" ]; then
    printf '{"deployment":"%s","installed_version":"%s"}\n' "$( [ -d "$plugin_dir/.git" ] && printf git_checkout || printf missing )" "$current"
    return 0
  fi

  local release tuple version archive_url archive_name evidence_type evidence extra
  if ! release="$(curl -fsSL "$DMC_MANAGED_RELEASE_API")" || ! tuple="$(dmc_managed_release_resolve "$release")"; then
    printf '{"deployment":"copied_deploy","installed_version":"%s","state":"resolution_failed"}\n' "$current"
    return 1
  fi
  IFS=$'\t' read -r version archive_url archive_name evidence_type evidence extra <<< "$tuple"
  if [ -n "$extra" ] || [ -z "$version" ] || [ -z "$archive_url" ] || [ -z "$archive_name" ] || [ -z "$evidence_type" ] || [ -z "$evidence" ]; then
    printf '{"deployment":"copied_deploy","installed_version":"%s","state":"resolution_failed"}\n' "$current"
    return 1
  fi
  if [ "$evidence_type" = github_digest ]; then
    printf '{"deployment":"copied_deploy","installed_version":"%s","latest_version":"%s","archive_url":"%s","expected_sha256":"%s"}\n' "$current" "$version" "$archive_url" "$evidence"
  else
    printf '{"deployment":"copied_deploy","installed_version":"%s","latest_version":"%s","archive_url":"%s","checksum_url":"%s"}\n' "$current" "$version" "$archive_url" "$evidence"
  fi
}

update_data_machine_code_copied_release() {
  local plugin_dir
  plugin_dir="$(dmc_managed_release_plugin_dir)"
  [ -d "$plugin_dir" ] || return 0
  [ ! -d "$plugin_dir/.git" ] || return 0

  local current release tuple target archive_url archive_name evidence_type evidence extra phase_status
  current="$(dmc_managed_release_header_version "$plugin_dir" 2>/dev/null || true)"
  if _dmc_managed_release_phase release-discovery curl -fsSL "$DMC_MANAGED_RELEASE_API"; then
    release="$PLUGIN_PHASE_OUTPUT"
  else
    phase_status=$?
    _dmc_managed_release_abort "Could not resolve the official Data Machine Code release — copied install unchanged" "$phase_status"
    return $?
  fi
  DMC_RELEASE_JSON="$release"; export DMC_RELEASE_JSON
  if _dmc_managed_release_phase release-resolution dmc_managed_release_resolve_environment; then
    tuple="$PLUGIN_PHASE_OUTPUT"
  else
    phase_status=$?
    unset DMC_RELEASE_JSON
    _dmc_managed_release_abort "Could not resolve the official Data Machine Code release — copied install unchanged" "$phase_status"
    return $?
  fi
  unset DMC_RELEASE_JSON
  IFS=$'\t' read -r target archive_url archive_name evidence_type evidence extra <<< "$tuple"
  if [ -n "$extra" ] || [ -z "$target" ] || [ -z "$archive_url" ] || [ -z "$archive_name" ] || [ -z "$evidence_type" ] || [ -z "$evidence" ]; then
    _dmc_managed_release_abort "Could not resolve the official Data Machine Code release — copied install unchanged"
    return $?
  fi

  if [ "$current" = "$target" ] && dmc_managed_release_pointer_matches "$plugin_dir" "$target" "$evidence_type" "$evidence"; then
    if [ "${DRY_RUN:-false}" != true ]; then
      dmc_managed_release_recover "$plugin_dir" || { _dmc_managed_release_abort "Could not recover interrupted Data Machine Code release update"; return $?; }
    fi
    log "Data Machine Code copied install already at official release $target"
    return 0
  fi
  if [ "$current" = "$target" ] && [ "$evidence_type" = github_digest ]; then
    local staged_release
    staged_release="$(dmc_managed_release_release_root)/$target-$evidence"
    if [ -d "$staged_release" ] && [ "$(dmc_managed_release_header_version "$staged_release" 2>/dev/null || true)" = "$target" ] && grep -Fq "\"sha256\":\"$evidence\"" "$staged_release/.wp-coding-agents-managed-release.json" 2>/dev/null; then
      if [ "${DRY_RUN:-false}" = true ]; then
        echo -e "${BLUE}[dry-run]${NC} Recover Data Machine Code $target from its verified staged release"
        return 0
      fi
      if ! dmc_managed_release_switch_pointer "$plugin_dir" "$staged_release"; then
        _dmc_managed_release_abort "Could not recover interrupted Data Machine Code release pointer"
        return $?
      fi
      _dmc_managed_release_phase ownership-normalization fix_ownership "$plugin_dir" || return $?
      UPDATED_ITEMS+=("data-machine-code $target (recovered official copied release)")
      log "Recovered Data Machine Code $target release pointer from its verified staged release"
      return 0
    fi
  fi
  if [ "${DRY_RUN:-false}" = true ]; then
    if [ "$evidence_type" = github_digest ]; then
      echo -e "${BLUE}[dry-run]${NC} Download and SHA-256 verify official Data Machine Code $target against $evidence"
    else
      echo -e "${BLUE}[dry-run]${NC} Download and SHA-256 verify official Data Machine Code $target using $evidence"
    fi
    echo -e "${BLUE}[dry-run]${NC} Stage and atomically deploy only $plugin_dir ($current → $target)"
    return 0
  fi

  local staging archive checksum expected actual extracted candidate staged releases release_dir legacy_dir legacy_name current loader_tmp
  staging="$(mktemp -d)" || { _dmc_managed_release_abort "Could not create Data Machine Code release staging directory"; return $?; }
  trap 'rm -rf "$staging"' RETURN
  archive="$staging/release.zip"
  if _dmc_managed_release_phase archive-download curl -fsSL "$archive_url" -o "$archive"; then
    :
  else
    phase_status=$?
    _dmc_managed_release_abort "Could not download official Data Machine Code release $target — copied install unchanged" "$phase_status"
    return $?
  fi
  if [ "$evidence_type" = github_digest ]; then
    expected="$evidence"
  else
    checksum="$staging/release.sha256"
    if _dmc_managed_release_phase checksum-download curl -fsSL "$evidence" -o "$checksum"; then
      :
    else
      phase_status=$?
      _dmc_managed_release_abort "Could not download official Data Machine Code release $target — copied install unchanged" "$phase_status"
      return $?
    fi
    expected="$(dmc_managed_release_expected_sha256 "$checksum" "$archive_name")"
  fi
  if _dmc_managed_release_phase archive-sha256 dmc_managed_release_sha256 "$archive"; then
    actual="$PLUGIN_PHASE_OUTPUT"
  else
    phase_status=$?
    _dmc_managed_release_abort "Could not hash official Data Machine Code release $target — copied install unchanged" "$phase_status"
    return $?
  fi
  if ! [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || [ "$actual" != "$expected" ]; then
    _dmc_managed_release_abort "Official Data Machine Code release $target failed published SHA-256 verification — copied install unchanged"
    return $?
  fi
  dmc_managed_release_recover "$plugin_dir" || { _dmc_managed_release_abort "Could not recover interrupted Data Machine Code release update"; return $?; }
  extracted="$staging/extracted"
  mkdir -p "$extracted"
  if _dmc_managed_release_phase archive-extraction unzip -q "$archive" -d "$extracted"; then
    :
  else
    phase_status=$?
    _dmc_managed_release_abort "Could not extract verified Data Machine Code release $target — copied install unchanged" "$phase_status"
    return $?
  fi
  candidate="$extracted"
  [ -f "$candidate/data-machine-code.php" ] || candidate="$(dirname "$(command find "$extracted" -mindepth 2 -maxdepth 2 -name data-machine-code.php -print -quit)")"
  if [ ! -f "$candidate/data-machine-code.php" ] || [ "$(dmc_managed_release_header_version "$candidate" 2>/dev/null || true)" != "$target" ]; then
    _dmc_managed_release_abort "Verified Data Machine Code release $target has no matching plugin entrypoint — copied install unchanged"
    return $?
  fi
  releases="$(dmc_managed_release_release_root)"
  current="$plugin_dir/.wp-coding-agents-release-current"
  # First conversion keeps a complete copy of the running copied deployment
  # behind current before replacing its entrypoint with the stable loader.
  # The release directory is excluded so copying into a child never recurses.
  if [ ! -e "$current/data-machine-code.php" ]; then
    legacy_dir="$staging/legacy"
    legacy_name="legacy-${TIMESTAMP:-$(date +%s)}"
    if _dmc_managed_release_phase current-release-preservation rsync -a --exclude='.wp-coding-agents-releases' --exclude='.wp-coding-agents-release-current' --exclude='.wp-coding-agents-release-previous' --exclude='.wp-coding-agents-release-next' "$plugin_dir/" "$legacy_dir/"; then
      :
    else
      phase_status=$?
      _dmc_managed_release_abort "Could not preserve the current Data Machine Code release before deployment" "$phase_status"
      return $?
    fi
    mkdir -p "$releases"
    if ! mv "$legacy_dir" "$releases/$legacy_name" || ! ln -s ".wp-coding-agents-releases/$legacy_name" "$current"; then
      _dmc_managed_release_abort "Could not prepare Data Machine Code interruption recovery"
      return $?
    fi
  fi
  release_dir="$releases/$target-$actual"
  mkdir -p "$releases"
  if [ ! -d "$release_dir" ]; then
    staged="$releases/.staging-$target-${TIMESTAMP:-$(date +%s)}"
    if _dmc_managed_release_phase release-staging cp -a "$candidate" "$staged"; then
      :
    else
      phase_status=$?
      _dmc_managed_release_abort "Could not stage Data Machine Code $target — copied install unchanged" "$phase_status"
      return $?
    fi
    printf '{"repository":"%s","version":"%s","sha256":"%s","archive_url":"%s"}\n' "$DMC_MANAGED_RELEASE_REPO" "$target" "$actual" "$archive_url" > "$staged/.wp-coding-agents-managed-release.json"
    mv "$staged" "$release_dir" || { _dmc_managed_release_abort "Could not stage Data Machine Code $target — copied install unchanged"; return $?; }
  fi
  # Keep activation state exactly as found. Inactive plugins are deployable but
  # must not become active as a side effect of an updater run.
  loader_tmp="$plugin_dir/.wp-coding-agents-loader-${TIMESTAMP:-$(date +%s)}.php"
  dmc_managed_release_loader "$target" > "$loader_tmp"
  mv "$loader_tmp" "$plugin_dir/data-machine-code.php" || { _dmc_managed_release_abort "Could not install Data Machine Code release loader"; return $?; }
  # There is always a loader-visible target: before current is replaced it sees
  # current; between the two renames it falls back to previous; afterward it
  # sees the new current. A later invocation restores previous -> current.
  if ! dmc_managed_release_switch_pointer "$plugin_dir" "$release_dir"; then
    _dmc_managed_release_abort "Could not switch Data Machine Code $target release pointer — prior release retained"
    return $?
  fi
  if [ "$(dmc_managed_release_header_version "$plugin_dir" 2>/dev/null || true)" != "$target" ] || ! grep -Fq "\"sha256\":\"$actual\"" "$(dmc_managed_release_provenance_file)"; then
    rm -f "$current"
    dmc_managed_release_recover "$plugin_dir" || true
    _dmc_managed_release_abort "Data Machine Code $target version/provenance verification failed — prior release restored"
    return $?
  fi
  _dmc_managed_release_phase ownership-normalization fix_ownership "$plugin_dir" || return $?
  UPDATED_ITEMS+=("data-machine-code $target (official copied release)")
}
