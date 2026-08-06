#!/bin/bash
# tests/source-reconcile.sh — continuous owned-source reconcile (#336).
#
# Derivation used to run only during upgrade.sh. That is enough for a plugin
# that already exists and useless for one the agent is about to write: it creates
# the directory, and nothing recomputes anything until somebody SSHes in. This
# makes the derivation reactive, which means it now runs UNATTENDED on a live
# site — so the properties that matter are the ones that hold when nobody is
# looking.
#
# The safety argument is unchanged and load-bearing: ownership is inferred only
# from the PRESENCE of evidence. The wp.org signal is a transient, and treating
# its absence as "nothing belongs to wp.org" would classify every plugin as the
# site's — granting the agent write access to WooCommerce and any payment
# gateway. Running that logic on a schedule rather than at an operator's
# keyboard raises the stakes rather than lowering them.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

FAILED=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [ "$got" = "$want" ]; then echo "  ok   $name"; else
    echo "  FAIL $name"; echo "         got:  $got"; echo "         want: $want"
    FAILED=$((FAILED + 1))
  fi
}
assert_contains() {
  case "$1" in *"$2"*) echo "  ok   $3" ;; *) echo "  FAIL $3 (missing: $2)"; FAILED=$((FAILED + 1)) ;; esac
}
refute_contains() {
  case "$1" in *"$2"*) echo "  FAIL $3 (unexpectedly present: $2)"; FAILED=$((FAILED + 1)) ;; *) echo "  ok   $3" ;; esac
}

TEMPLATE="templates/wp-coding-agents-source-reconcile.php"

echo "source-reconcile: the mu-plugin is valid PHP"
if php -l "$TEMPLATE" >/dev/null 2>&1; then
  echo "  ok   template parses"
else
  echo "  FAIL template does not parse"
  php -l "$TEMPLATE" 2>&1 | sed 's/^/         /'
  FAILED=$((FAILED + 1))
fi

echo ""
echo "source-reconcile: never widens on missing evidence"

# A harness that loads the template's functions against stubbed WordPress state,
# so the derivation can be exercised without a site.
run_php() {
  php -r "
    define('ABSPATH', '$TMP/');
    define('DAY_IN_SECONDS', 86400);
    \$GLOBALS['opts'] = ${2:-array()};
    \$GLOBALS['transient'] = ${3:-null};
    \$GLOBALS['theme_transient'] = ${6:-\$GLOBALS['transient']};
    \$GLOBALS['themes'] = ${4:-array()};
    \$GLOBALS['plugins'] = ${5:-array()};
    function add_action(...\$a) {}
    function add_filter(...\$a) {}
    function apply_filters(\$h, \$v) { return \$v; }
    function do_action(...\$a) {}
    function wp_next_scheduled(...\$a) { return true; }
    function wp_schedule_event(...\$a) {}
    function get_option(\$k, \$d = '') { return \$GLOBALS['opts'][\$k] ?? \$d; }
    function update_option(\$k, \$v, \$a = null) { \$GLOBALS['opts'][\$k] = \$v; return true; }
    function get_site_transient(\$k) { return \$k === 'update_plugins' ? \$GLOBALS['transient'] : (\$GLOBALS['theme_transient'] ?? null); }
    function get_plugins() { return \$GLOBALS['plugins']; }
    function wp_get_themes() { return \$GLOBALS['themes']; }
    function wp_parse_url(\$u, \$c = -1) { return 'example.com'; }
    function home_url() { return 'https://example.com'; }
    function trailingslashit(\$s) { return rtrim(\$s, '/') . '/'; }
    function wp_json_encode(\$d, \$f = 0) { return json_encode(\$d, \$f); }
    require '$TEMPLATE';
    $1
  " 2>&1
}

FRESH="(object) array('last_checked' => time(), 'response' => array(), 'no_update' => array('woocommerce/woocommerce.php' => 1, 'akismet/akismet.php' => 1))"
PLUGINS="array('woocommerce/woocommerce.php' => array(), 'akismet/akismet.php' => array(), 'data-machine/data-machine.php' => array(), 'h44-core/h44-core.php' => array(), 'hello.php' => array())"
THEMES="array('h44-lacrosse-theme' => 1, 'twentytwentyfive' => 1)"
# wp.org's THEME transient is separate from the plugin one and needs its own
# fixture: reusing the plugin transient would leave every theme unrecognised.
FRESH_THEMES="(object) array('last_checked' => time(), 'response' => array(), 'no_update' => array('twentytwentyfive' => 1))"

OUT="$(run_php 'print_r(wp_coding_agents_derive_owned_sources());' "array()" "$FRESH" "$THEMES" "$PLUGINS" "$FRESH_THEMES")"
assert_contains "$OUT" "wp-content/plugins/h44-core" "derives the site's own plugin"
assert_contains "$OUT" "wp-content/themes/h44-lacrosse-theme" "derives the site's own theme"
refute_contains "$OUT" "plugins/woocommerce" "excludes a wp.org plugin"
refute_contains "$OUT" "plugins/akismet" "excludes another"
refute_contains "$OUT" "plugins/data-machine" "excludes the agent's own runtime"
refute_contains "$OUT" "themes/twentytwentyfive" "excludes a bundled theme"
# A single-file plugin has no directory to own; capturing it would mean
# capturing all of wp-content/plugins.
refute_contains "$OUT" "hello" "ignores a single-file plugin"

# Each of these is the same danger wearing a different costume.
# A fresh plugin signal with a broken THEME signal must also defer: otherwise
# every bundled theme looks unrecognised and derives as the site's.
OUT="$(run_php 'var_dump(null === wp_coding_agents_derive_owned_sources());' "array()" "$FRESH" "$THEMES" "$PLUGINS" "null")"
assert_contains "$OUT" "bool(true)" "refuses when only the THEME signal is broken"

for label in missing stale empty; do
  case "$label" in
    missing) T="null" ;;
    stale)   T="(object) array('last_checked' => time() - 999999, 'no_update' => array('woocommerce/woocommerce.php' => 1))" ;;
    empty)   T="(object) array('last_checked' => time(), 'response' => array(), 'no_update' => array())" ;;
  esac
  OUT="$(run_php 'var_dump(null === wp_coding_agents_derive_owned_sources());' "array()" "$T" "$THEMES" "$PLUGINS")"
  assert_contains "$OUT" "bool(true)" "refuses to derive from a $label signal"
done

# The catastrophe asserted directly rather than implied.
OUT="$(run_php 'print_r(wp_coding_agents_derive_owned_sources());' "array()" "null" "$THEMES" "$PLUGINS")"
refute_contains "$OUT" "woocommerce" "a missing signal cannot open WooCommerce"

echo ""
echo "source-reconcile: reconcile is gated and fails closed"

# Workspace installs derive nothing.
OUT="$(run_php 'print_r(wp_coding_agents_reconcile_sources(true));' "array('wp_coding_agents_source_mode' => 'workspace')" "$FRESH" "$THEMES" "$PLUGINS" "$FRESH_THEMES")"
assert_contains "$OUT" "skipped" "does nothing outside owned mode"

# An untrustworthy signal defers instead of writing a widened set.
OUT="$(run_php 'print_r(wp_coding_agents_reconcile_sources(true));' "array('wp_coding_agents_source_mode' => 'owned')" "null" "$THEMES" "$PLUGINS")"
assert_contains "$OUT" "deferred" "defers when the signal is untrustworthy"
refute_contains "$OUT" "reconciled" "and does not report success"

# A site that owns nothing gets no editable source, rather than a fallback that
# opens wp-content wholesale.
EMPTY_PLUGINS="array('woocommerce/woocommerce.php' => array())"
OUT="$(run_php 'print_r(wp_coding_agents_reconcile_sources(true));' "array('wp_coding_agents_source_mode' => 'owned')" "$FRESH" "array()" "$EMPTY_PLUGINS" "$FRESH_THEMES")"
assert_contains "$OUT" "deferred" "an empty derived set defers rather than writing one"

# The operator exclusion still applies on the reactive path.
OUT="$(run_php 'print_r(wp_coding_agents_derive_owned_sources());' "array('wp_coding_agents_not_owned' => 'h44-core')" "$FRESH" "$THEMES" "$PLUGINS" "$FRESH_THEMES")"
refute_contains "$OUT" "plugins/h44-core" "--not-owned is honoured by the reactive path"

echo ""
echo "source-reconcile: the inventory hash makes hot hooks cheap"

OUT="$(run_php 'echo wp_coding_agents_inventory_hash();' "array()" "$FRESH" "$THEMES" "$PLUGINS" "$FRESH_THEMES")"
OUT2="$(run_php 'echo wp_coding_agents_inventory_hash();' "array()" "$FRESH" "$THEMES" "$PLUGINS" "$FRESH_THEMES")"
assert_eq "$OUT" "$OUT2" "the hash is stable for an unchanged inventory"
OUT3="$(run_php 'echo wp_coding_agents_inventory_hash();' "array()" "$FRESH" "$THEMES" "array('h44-core/h44-core.php' => array())" "$FRESH_THEMES")"
if [ "$OUT" != "$OUT3" ]; then echo "  ok   the hash changes when a plugin appears"; else
  echo "  FAIL the hash did not change for a different inventory"; FAILED=$((FAILED + 1)); fi

echo ""
echo "source-reconcile: wiring"

# A scaffolded plugin fires none of the lifecycle hooks — no install, no
# activation, just a directory appearing. That is the case this exists for, so
# the scheduled sweep is not optional.
tpl="$(cat "$TEMPLATE")"
assert_contains "$tpl" "activated_plugin" "hooks plugin activation"
assert_contains "$tpl" "upgrader_process_complete" "hooks installs and updates"
assert_contains "$tpl" "wp_coding_agents_reconcile_cron" "schedules a sweep for scaffolded plugins"

# The shell must delegate, not re-derive: two implementations of the same safety
# rule are free to drift, which is the failure this design removes.
recon="$(cat lib/source-reconcile.sh)"
assert_contains "$recon" "wp_coding_agents_reconcile_sources" "the installer delegates to the mu-plugin"
refute_contains "$recon" "update_plugins" "the installer does not re-derive from the transient"

# PHP runs as www-data and writes the manifest. Setup created that directory
# root-owned, so the reactive path could not write it and capture would read a
# stale file — the drift the manifest exists to prevent.
assert_contains "$recon" "source_reconcile_prepare_manifest_dir" "the manifest dir is prepared for PHP"
assert_contains "$recon" "chown root:www-data" "and made group-writable by the web user"

for f in setup.sh upgrade.sh; do
  assert_contains "$(cat $f)" "source_reconcile_sync" "$f installs the reconciler"
  assert_contains "$(cat $f)" "source_reconcile_run" "$f converges once on run"
done

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "source-reconcile: all assertions passed"
else
  echo "source-reconcile: $FAILED assertion(s) failed"
  exit 1
fi
