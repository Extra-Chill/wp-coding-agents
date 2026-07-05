#!/bin/bash
# AGENTS.md backup retention helpers.

agents_md_prune_backups() {
  local site_path="$1"
  local keep="${AGENTS_MD_BACKUP_KEEP:-5}"
  local max_age_days="${AGENTS_MD_BACKUP_MAX_AGE_DAYS:-30}"

  if [ -z "$site_path" ] || [ ! -d "$site_path" ]; then
    return 0
  fi

  case "$keep" in
    ''|*[!0-9]*) keep=5 ;;
  esac
  case "$max_age_days" in
    ''|*[!0-9]*) max_age_days=30 ;;
  esac

  if [ "${DRY_RUN:-false}" = true ]; then
    _agents_md_backup_log "  Would prune AGENTS.md backups in $site_path (keep latest $keep, prune older than ${max_age_days}d)"
    return 0
  fi

  local output pruned
  output=$(AGENTS_MD_BACKUP_DIR="$site_path" AGENTS_MD_BACKUP_KEEP="$keep" AGENTS_MD_BACKUP_MAX_AGE_DAYS="$max_age_days" python3 <<'PY'
import os
import re
import time

directory = os.environ.get("AGENTS_MD_BACKUP_DIR", "")
keep = int(os.environ.get("AGENTS_MD_BACKUP_KEEP", "5"))
max_age_days = int(os.environ.get("AGENTS_MD_BACKUP_MAX_AGE_DAYS", "30"))
pattern = re.compile(r"^AGENTS\.md\.backup\.(\d{8}-\d{6})$")

try:
    names = os.listdir(directory)
except OSError:
    print("0")
    raise SystemExit(0)

backups = []
for name in names:
    match = pattern.match(name)
    if not match:
        continue
    path = os.path.join(directory, name)
    try:
        stat = os.stat(path)
    except OSError:
        continue
    if not os.path.isfile(path):
        continue
    backups.append((match.group(1), path, stat.st_mtime))

backups.sort(key=lambda item: item[0], reverse=True)
protected = {path for _stamp, path, _mtime in backups[:keep]}
threshold = time.time() - (max_age_days * 86400)
pruned = 0

for _stamp, path, mtime in backups[keep:]:
    if path in protected or mtime >= threshold:
        continue
    try:
        os.remove(path)
        pruned += 1
    except OSError:
        pass

print(str(pruned))
PY
  ) || {
    _agents_md_backup_warn "  Could not prune AGENTS.md backups"
    return 0
  }

  pruned="${output##*$'\n'}"
  case "$pruned" in
    ''|*[!0-9]*) pruned=0 ;;
  esac

  if [ "$pruned" -gt 0 ]; then
    _agents_md_backup_log "  Pruned $pruned old AGENTS.md backup(s) (kept latest $keep; max age ${max_age_days}d)"
  fi
}

_agents_md_backup_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$1"
  else
    printf '%s\n' "$1"
  fi
}

_agents_md_backup_warn() {
  if declare -F warn >/dev/null 2>&1; then
    warn "$1"
  else
    printf '%s\n' "$1" >&2
  fi
}
