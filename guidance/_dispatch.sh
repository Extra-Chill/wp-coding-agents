#!/bin/bash
# guidance/_dispatch.sh — auto-discovery + dispatch for guidance/*.sh.
#
# Mirrors bridges/_dispatch.sh and runtimes/*.sh: each guidance file is a
# self-contained AGENTS.md section unit that owns its own id, priority, label,
# applicability, and prose. Adding a section is "drop a file in guidance/" — no
# edits to lib/, setup.sh, upgrade.sh, or this file.
#
# WHY THIS EXISTS
#
# lib/agents-md-guidance.sh is the MECHANISM: it scaffolds the mu-plugin,
# renders marker-delimited PHP blocks, and rewrites them idempotently. It used
# to also carry the CONTENT — the actual prose for every section — as heredocs
# inside sync functions. That coupling meant every new section, and every
# source-mode variant of an existing section, grew the same file. This directory is
# the content half; lib/agents-md-guidance.sh no longer knows what WordPress or
# Homeboy are.
#
# SOURCE_MODE VARIANTS
#
# A section whose prose depends on the install source mode (see lib/source-policy.sh)
# ships one file per mode:
#
#   guidance/wordpress-source.engineering.sh
#   guidance/wordpress-source.managed.sh
#
# Resolution for section <id> is `<id>.<mode>.sh` when present, else
# `<id>.sh`. Mode-neutral sections ship a single `<id>.sh` and are unaffected.
# Two files that differ wholesale beat one file with a conditional wrapped
# around a heredoc: the diff of a mode is the file, and neither variant can
# quietly inherit a clause meant for the other.
#
# HOOK CONTRACT (functions namespaced guidance_* inside each unit file)
#
#   Mandatory:
#     guidance_id            — SectionRegistry section id (stable across modes)
#     guidance_priority      — integer sort key within AGENTS.md
#     guidance_label         — human label recorded in section metadata
#     guidance_render        — emit the section markdown on stdout
#
#   Optional:
#     guidance_description   — metadata blurb (default: empty)
#     guidance_freshness     — static | conditional | live (default: static)
#     guidance_conditions    — metadata note on when the section applies
#     guidance_applies       — return non-zero to UNREGISTER instead of register.
#                              Use for presence-gated sections (e.g. homeboy).
#     guidance_register      — take over registration entirely. Units that must
#                              emit a hand-written PHP block (rather than static
#                              markdown) implement this instead of guidance_render.
#
# Units are sourced in a SUBSHELL for every operation, so definitions never leak
# between units and a unit is free to define `_helpers` without collisions.

if [ -n "${SCRIPT_DIR:-}" ] && [ -d "$SCRIPT_DIR/guidance" ]; then
  GUIDANCE_DIR="$SCRIPT_DIR/guidance"
else
  GUIDANCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# guidance_names — every discoverable section id, one per line, de-duplicated.
#
# Discovery: any guidance/*.sh whose basename does not start with `_`. A
# `<id>.<mode>.sh` filename contributes the id once, no matter how many
# mode variants exist.
guidance_names() {
  local f base id seen=""
  for f in "$GUIDANCE_DIR"/*.sh; do
    [ -f "$f" ] || continue
    base="$(basename "$f" .sh)"
    case "$base" in
      _*) continue ;;
    esac
    id="${base%%.*}"
    case " $seen " in
      *" $id "*) continue ;;
    esac
    seen="$seen $id"
    echo "$id"
  done
}

# guidance_file <id> — absolute path to the unit for the active source mode.
#
# Prefers the mode-specific variant, falls back to the neutral file.
guidance_file() {
  local id="$1"
  local mode="${SOURCE_MODE:-workspace}"

  if [ -f "$GUIDANCE_DIR/${id}.${mode}.sh" ]; then
    printf '%s' "$GUIDANCE_DIR/${id}.${mode}.sh"
    return 0
  fi

  if [ -f "$GUIDANCE_DIR/${id}.sh" ]; then
    printf '%s' "$GUIDANCE_DIR/${id}.sh"
    return 0
  fi

  return 1
}

# guidance_sync_unit <id> — register or unregister one section.
#
# Registration goes through lib/agents-md-guidance.sh, which stays responsible
# for idempotency: an unchanged block is not rewritten.
guidance_sync_unit() {
  local id="$1"
  local f
  f="$(guidance_file "$id")" || {
    warn "  guidance_sync_unit: unknown section '$id'"
    return 1
  }

  # The unit NAME (filename) and the SectionRegistry section id are distinct:
  # guidance/homeboy.sh owns section 'homeboy-cli'. Always address the registry
  # by guidance_id, or an unregister silently misses the block it meant to
  # remove.
  local section_id
  section_id="$(guidance_call "$id" id)"

  # Applicability and custom registration run in a subshell that has the unit
  # sourced; everything they need from the parent is already exported.
  if ! (
    # shellcheck disable=SC1090
    source "$f"
    if declare -F guidance_applies >/dev/null 2>&1; then
      guidance_applies
    fi
  ); then
    agents_md_guidance_unregister "$section_id"
    return 0
  fi

  if (
    # shellcheck disable=SC1090
    source "$f"
    declare -F guidance_register >/dev/null 2>&1
  ); then
    (
      # shellcheck disable=SC1090
      source "$f"
      guidance_register
    )
    return $?
  fi

  local priority label description freshness conditions content
  priority="$(guidance_call "$id" priority)"
  label="$(guidance_call "$id" label)"
  description="$(guidance_call "$id" description 2>/dev/null || true)"
  freshness="$(guidance_call "$id" freshness 2>/dev/null || true)"
  conditions="$(guidance_call "$id" conditions 2>/dev/null || true)"
  content="$(guidance_call "$id" render)"

  AGENTS_MD_GUIDANCE_FRESHNESS="${freshness:-static}" \
    AGENTS_MD_GUIDANCE_CONDITIONS="${conditions:-Registered by wp-coding-agents on managed WordPress coding-agent installations.}" \
    agents_md_guidance_register \
      "$section_id" \
      "$priority" \
      "$label" \
      "$description" \
      "$content"
}

# guidance_call <id> <hook> [args...] — invoke one hook in a subshell.
guidance_call() {
  local id="$1" hook="$2"
  shift 2
  local f
  f="$(guidance_file "$id")" || return 1
  (
    # shellcheck disable=SC1090
    source "$f"
    if ! declare -F "guidance_${hook}" >/dev/null; then
      exit 2
    fi
    "guidance_${hook}" "$@"
  )
}

# guidance_sync_all — sync every discovered section for the active source mode.
#
# Called once from setup.sh and once from upgrade.sh. Individual units may also
# be synced on their own (lib/homeboy.sh re-syncs the homeboy section after the
# binary's availability is settled); both paths are idempotent.
guidance_sync_all() {
  agents_md_guidance_sync_wp_cli_transport

  local id
  for id in $(guidance_names); do
    guidance_sync_unit "$id"
  done
}
