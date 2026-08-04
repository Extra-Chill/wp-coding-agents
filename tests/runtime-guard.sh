#!/bin/bash
# tests/runtime-guard.sh — the agent runtime must survive the wp-admin plugins screen.
#
# Hiding the Deactivate link is presentation only; the request can still arrive
# by URL, bulk action, or any caller of deactivate_plugins(). The server-side
# refusal is the half that actually holds, so it is asserted behaviourally
# rather than by grepping for the hook. See #328.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILED=0
check() { if [ "$1" -eq 0 ]; then echo "  ok   $2"; else echo "  FAIL $2"; FAILED=$((FAILED + 1)); fi; }

export SITE_PATH="$TMP/site"
mkdir -p "$SITE_PATH/wp-content/mu-plugins"
touch "$SITE_PATH/wp-config.php"
export SCRIPT_DIR DRY_RUN=false
export SITE="$SITE_PATH"
UPDATED_ITEMS=()
log() { :; }
warn() { printf '%s\n' "$*" >&2; }

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/source-policy.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/runtime-guard.sh"
service_file_normalize_perms() { :; }
wp_cmd() { printf 'data-machine/data-machine.php\ndata-machine-business/data-machine-business.php\n'; }

GUARD="$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-runtime-guard.php"

echo "==> the guard is posture-scoped"
POSTURE=engineering runtime_guard_sync
[ ! -f "$GUARD" ]; check $? "engineering installs no guard"

POSTURE=managed runtime_guard_sync
[ -f "$GUARD" ]; check $? "managed installs the guard"
php -l "$GUARD" >/dev/null 2>&1; check $? "generated guard parses"

grep -q "data-machine-business/data-machine-business.php" "$GUARD"
check $? "companion plugins are discovered, not assumed"

# A posture switch must clean up, or an engineering install keeps a guard
# nothing maintains.
POSTURE=engineering runtime_guard_sync
[ ! -f "$GUARD" ]; check $? "switching to engineering removes the guard"
POSTURE=managed runtime_guard_sync >/dev/null

echo "==> behaviour: links hidden, request refused"
php -r '
$site = getenv("SITE");
$died = null;
$actions_seen = null;
function add_filter($h,$c,$p=10,$a=1){ $GLOBALS["f"][$h][]=$c; }
function add_action($h,$c,$p=10,$a=1){ $GLOBALS["f"][$h][]=$c; }
function apply_filters($h,$v){ foreach(($GLOBALS["f"][$h]??[]) as $c){ $v=$c($v); } return $v; }
// Dispatch through the registry. Calling the functions directly would pass
// even if nobody had wired them to a hook.
function fire($h, ...$args){
  if (empty($GLOBALS["f"][$h])) { fwrite(STDERR, "NOT_HOOKED:$h\n"); exit(20); }
  foreach ($GLOBALS["f"][$h] as $c) { $c(...$args); }
}
function filter_links($plugin, $actions){
  if (empty($GLOBALS["f"]["plugin_action_links"])) { fwrite(STDERR,"NOT_HOOKED:plugin_action_links\n"); exit(21); }
  foreach ($GLOBALS["f"]["plugin_action_links"] as $c) { $actions = $c($actions, $plugin); }
  return $actions;
}
function esc_attr($s){ return $s; } function esc_html($s){ return $s; }
function esc_attr__($s,$d=null){ return $s; } function esc_html__($s,$d=null){ return $s; }
function is_admin(){ return true; }
function wp_doing_cron(){ return false; }
function wp_die($m,$t="",$a=[]){ throw new RuntimeException("WPDIE:".$m); }
define("ABSPATH", "/");
require $site."/wp-content/mu-plugins/wp-coding-agents-runtime-guard.php";

// action links for a guarded plugin
$a = ["activate"=>"x","deactivate"=>"<a>Deactivate</a>","delete"=>"<a>Delete</a>"];
$out = filter_links("data-machine/data-machine.php", $a);
if (isset($out["deactivate"]) || isset($out["delete"])) { fwrite(STDERR,"LINKS_PRESENT\n"); exit(2); }
if (!isset($out["wp-coding-agents-guard"])) { fwrite(STDERR,"NO_EXPLANATION\n"); exit(3); }

// an unrelated plugin keeps its links
$b = filter_links("akismet/akismet.php", $a);
if (!isset($b["deactivate"])) { fwrite(STDERR,"UNRELATED_STRIPPED\n"); exit(4); }

// a forged deactivation of a guarded plugin is refused
try { fire("deactivate_plugin", "data-machine/data-machine.php"); fwrite(STDERR,"NOT_BLOCKED\n"); exit(5); }
catch (RuntimeException $e) { if (strpos($e->getMessage(),"WPDIE:")!==0) { exit(6); } }

// an unrelated plugin deactivates normally
try { fire("deactivate_plugin", "akismet/akismet.php"); }
catch (RuntimeException $e) { fwrite(STDERR,"UNRELATED_BLOCKED\n"); exit(7); }

// bulk action containing a guarded plugin is refused
try { fire("delete_plugin", "data-machine/data-machine.php"); fwrite(STDERR,"DELETE_NOT_BLOCKED\n"); exit(8); }
catch (RuntimeException $e) {}
echo "OK\n";
' >/dev/null 2>"$TMP/err"
check $? "links removed, explanation shown, forged and bulk requests refused, unrelated plugins untouched"
[ -s "$TMP/err" ] && sed 's/^/    /' "$TMP/err"

echo "==> WP-CLI recovery stays open"
php -r '
$site = getenv("SITE");
function add_filter($h,$c,$p=10,$a=1){} function add_action($h,$c,$p=10,$a=1){ $GLOBALS["f"][$h][]=$c; }
function apply_filters($h,$v){ return $v; }
function fire($h, ...$args){ foreach (($GLOBALS["f"][$h]??[]) as $c) { $c(...$args); } }
function esc_attr($s){return $s;} function esc_html($s){return $s;}
function esc_attr__($s,$d=null){return $s;} function esc_html__($s,$d=null){return $s;}
function is_admin(){ return true; }
function wp_doing_cron(){ return false; }
function wp_die($m,$t="",$a=[]){ throw new RuntimeException("WPDIE"); }
define("ABSPATH","/"); define("WP_CLI", true);
require $site."/wp-content/mu-plugins/wp-coding-agents-runtime-guard.php";
try { fire("deactivate_plugin", "data-machine/data-machine.php"); }
catch (RuntimeException $e) { fwrite(STDERR,"CLI_BLOCKED\n"); exit(1); }
echo "OK\n";
' >/dev/null 2>&1
check $? "wp plugin deactivate is not blocked — operator recovery is preserved"

[ "$FAILED" -eq 0 ] || { echo; echo "FAILED: $FAILED"; exit 1; }
echo
echo "OK: runtime guard assertions passed"
