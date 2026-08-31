#!/bin/bash
# lib/owned-source-discovery.sh — derive the owned source set from site state.
#
# WHY THIS EXISTS
#
# Owned mode needs to know which plugins and themes belong to the SITE, as
# opposed to WordPress, wp.org, or the agent's own runtime. Until now that was
# an operator action: `--owned-source` per component, over SSH, repeated in the
# capture configuration. A non-technical owner asking for a new plugin therefore
# had to file a support ticket, which is exactly what managed hosting is
# supposed to remove.
#
# Ownership is not a judgement call, though. It is a fact already present on the
# box, and it can be derived:
#
#   owned = installed  −  known to wp.org  −  installed by wp-coding-agents
#                      −  explicitly excluded
#
# Measured against h44lacrosse.com, that yields h44-lacrosse-theme, h44-core and
# h44-forms — the three components previously declared by hand — plus one
# vendor plugin that needs the exclusion escape hatch below.
#
# THE FAILURE MODE THAT MATTERS
#
# The wp.org signal is a TRANSIENT. On a fresh install, after a cache flush, or
# when wp.org is unreachable, `update_plugins` is missing or stale — and then
# NOTHING looks known to wp.org and EVERYTHING classifies as owned. On
# h44lacrosse.com that would hand the agent write access to WooCommerce and a
# Stripe payment gateway.
#
# So this module fails CLOSED in the widening direction. A signal that cannot be
# trusted produces no derivation at all, and the caller keeps the last recorded
# set. Ownership is never inferred from the ABSENCE of evidence, only from its
# presence. That asymmetry is the whole safety argument: a missing signal must
# never be able to open a payment plugin.
#
# WHY NOT THE `Update URI` HEADER
#
# WP 5.8+ defines exactly the header this needs — a plugin declaring an external
# update source is by definition not the site's. It would generalise past wp.org
# to premium and vendor plugins. It is unusable in practice: measured across
# every plugin on h44lacrosse.com, including WooCommerce, the Stripe gateway and
# Akismet, not one sets it.
#
# Public surface:
#   owned_discovery_supported            # 0 when the site can be queried
#   owned_discovery_signal_fresh         # 0 when the wp.org signal is trustworthy
#   owned_discovery_carried_plugins      # slugs wp-coding-agents installs
#   owned_discovery_excluded             # operator exclusions (recorded)
#   owned_discovery_add_exclusion <slug>
#   owned_discovery_derive               # newline-separated wp-content paths, or
#                                        # nonzero when the signal is untrustworthy
#
# Honors DRY_RUN for writes; reads always happen.

# Slugs an operator has declared are NOT the site's, despite classifying as
# owned. The escape hatch for the two cases derivation cannot see:
#
#   - a premium or vendor plugin, which is on nobody's wp.org list and is not
#     carried by wp-coding-agents, but is no more the site's than WooCommerce
#     is. Editing it is futile — the vendor's next update overwrites it — and
#     capturing it may put licensed code in the operator's repository.
#   - anything else the operator knows better about than a heuristic does.
OWNED_DISCOVERY_EXCLUDED_OPTION="wp_coding_agents_not_owned"

# How stale the wp.org signal may be before it stops being evidence. WordPress
# refreshes update transients roughly twice daily; a couple of days tolerates a
# quiet site or a brief wp.org outage without tolerating a cleared cache.
OWNED_DISCOVERY_MAX_SIGNAL_AGE="${OWNED_DISCOVERY_MAX_SIGNAL_AGE:-172800}"

# Plugin slugs wp-coding-agents installs and updates itself.
#
# These are not the site's: they are the agent's own runtime, replaced wholesale
# by the next upgrade. An agent editing them in place loses the edit, and
# capturing them would commit this project's source into the site's repository.
#
# MUST track what lib/data-machine.sh actually installs. Anything else
# wp-coding-agents places on a site — an EXTRA_PLUGINS entry, a vendor
# plugin — is not visible here and belongs in the exclusion list.
owned_discovery_carried_plugins() {
  cat <<'EOF'
data-machine
data-machine-code
wp-codebox
wp-coding-agents-integration
ai-provider-for-claude-code
EOF
}

# 0 when the site can be queried at all.
owned_discovery_supported() {
  [ -n "${SITE_PATH:-}" ] || return 1
  [ -f "$SITE_PATH/wp-config.php" ] || return 1
  return 0
}

# Run a PHP snippet against the site. Reads only, and deliberately not through
# run_cmd: a dry run must still be able to SEE, or it reports a derivation that
# has nothing to do with what an apply would do.
_owned_discovery_eval() {
  owned_discovery_supported || return 1
  wp_cmd eval "$1" 2>/dev/null || true
}

# 0 when the wp.org signal is present and recent enough to be evidence.
#
# This is the gate that keeps a missing signal from widening the editable set.
owned_discovery_signal_fresh() {
  local age
  age="$(_owned_discovery_eval '
    $t = get_site_transient("update_plugins");
    if (!$t || empty($t->last_checked)) { echo "missing"; exit; }
    $known = array_merge(
      array_keys((array) ($t->response ?? [])),
      array_keys((array) ($t->no_update ?? []))
    );
    // A transient with no known plugins is not evidence that no plugin is
    // known to wp.org; it is evidence the check has not really run.
    if (!$known) { echo "empty"; exit; }
    echo (time() - (int) $t->last_checked);
  ')"

  case "$age" in
    ''|missing|empty) return 1 ;;
    *[!0-9]*) return 1 ;;
  esac
  [ "$age" -le "$OWNED_DISCOVERY_MAX_SIGNAL_AGE" ] || return 1
  return 0
}

# Slugs wp.org knows about, plugins and themes, one per line.
_owned_discovery_wporg_slugs() {
  _owned_discovery_eval '
    $out = [];
    $p = get_site_transient("update_plugins");
    if ($p) {
      foreach (array_merge(
        array_keys((array) ($p->response ?? [])),
        array_keys((array) ($p->no_update ?? []))
      ) as $file) {
        // "woocommerce/woocommerce.php" -> "woocommerce"; "hello.php" -> "hello"
        $out[] = strpos($file, "/") !== false
          ? substr($file, 0, strpos($file, "/"))
          : basename($file, ".php");
      }
    }
    $t = get_site_transient("update_themes");
    if ($t) {
      foreach (array_merge(
        array_keys((array) ($t->response ?? [])),
        array_keys((array) ($t->no_update ?? []))
      ) as $slug) {
        $out[] = $slug;
      }
    }
    echo implode("\n", array_unique($out));
  '
}

# Installed plugin and theme slugs, as `<kind> <slug>` lines.
_owned_discovery_installed() {
  _owned_discovery_eval '
    foreach (get_plugins() as $file => $data) {
      $slug = strpos($file, "/") !== false
        ? substr($file, 0, strpos($file, "/"))
        : basename($file, ".php");
      echo "plugins $slug\n";
    }
    foreach (wp_get_themes() as $slug => $theme) { echo "themes $slug\n"; }
  '
}

# Operator exclusions, one slug per line.
owned_discovery_excluded() {
  local recorded=""
  if declare -F _source_policy_option_read >/dev/null 2>&1; then
    recorded="$(_source_policy_option_read "$OWNED_DISCOVERY_EXCLUDED_OPTION")"
  fi
  printf '%s\n' "${OWNED_DISCOVERY_EXCLUSIONS:-}" "$recorded" | sed '/^[[:space:]]*$/d'
}

# Add an exclusion from the command line. Slug only — the derivation works in
# slugs, and accepting a path here would invite one that does not correspond to
# anything installed.
owned_discovery_add_exclusion() {
  local slug="$1"
  case "$slug" in
    ''|*/*|*' '*) error "--not-owned takes a plugin or theme slug, not '$slug'." ;;
  esac
  if [ -z "${OWNED_DISCOVERY_EXCLUSIONS:-}" ]; then
    OWNED_DISCOVERY_EXCLUSIONS="$slug"
  else
    OWNED_DISCOVERY_EXCLUSIONS="$OWNED_DISCOVERY_EXCLUSIONS
$slug"
  fi
}

# Persist the exclusions so later upgrades derive the same set without the flag.
owned_discovery_record_exclusions() {
  local excluded
  excluded="$(printf '%s\n' "${OWNED_DISCOVERY_EXCLUSIONS:-}" | sed '/^[[:space:]]*$/d')"
  [ -n "$excluded" ] || return 0

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} $(wp_cli_transport_display) option update $OWNED_DISCOVERY_EXCLUDED_OPTION '<${excluded}>'"
    return 0
  fi
  owned_discovery_supported || return 0

  local current=""
  current="$(_source_policy_option_read "$OWNED_DISCOVERY_EXCLUDED_OPTION")"
  [ "$current" = "$excluded" ] && return 0

  if printf '%s' "$excluded" | wp_cmd option update "$OWNED_DISCOVERY_EXCLUDED_OPTION" >/dev/null 2>&1; then
    log "  Recorded not-owned exclusions: $(printf '%s' "$excluded" | tr '\n' ' ')"
  fi
}

# Derive the owned set as wp-content-relative paths.
#
# Returns nonzero WITHOUT output when the wp.org signal cannot be trusted, so a
# caller can keep its last recorded set. Never widens on missing evidence.
owned_discovery_derive() {
  owned_discovery_supported || return 1
  owned_discovery_signal_fresh || return 1

  local wporg carried excluded installed kind slug
  wporg="$(_owned_discovery_wporg_slugs)"
  carried="$(owned_discovery_carried_plugins)"
  excluded="$(owned_discovery_excluded)"
  installed="$(_owned_discovery_installed)"

  [ -n "$installed" ] || return 1

  printf '%s\n' "$installed" | while read -r kind slug; do
    [ -n "$kind" ] && [ -n "$slug" ] || continue
    printf '%s\n' "$wporg"    | grep -qxF "$slug" && continue
    printf '%s\n' "$carried"  | grep -qxF "$slug" && continue
    printf '%s\n' "$excluded" | grep -qxF "$slug" && continue
    printf 'wp-content/%s/%s\n' "$kind" "$slug"
  done
}
