#!/bin/bash
# tests/site-identity-guard.sh — the agent home site keeps its identity.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SCRIPT_DIR SITE_PATH="$TMP/site" DRY_RUN=false
UPDATED_ITEMS=()
log() { :; }
warn() { printf '%s\n' "$*" >&2; }
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/site-identity-guard.sh"
service_file_normalize_perms() { chmod 0664 "$1"; }
GUARD="$(site_identity_guard_mu_plugin_path)"
export GUARD
unset WP_CODING_AGENTS_ALLOW_SITE_IDENTITY_CHANGE

for mode in workspace owned; do
  rm -f "$GUARD"
  SOURCE_MODE="$mode" site_identity_guard_sync
  cmp "$SCRIPT_DIR/templates/wp-coding-agents-site-identity-guard.php" "$GUARD"
  php -l "$GUARD"
  before="${#UPDATED_ITEMS[@]}"
  SOURCE_MODE="$mode" site_identity_guard_sync
  [ "${#UPDATED_ITEMS[@]}" -eq "$before" ]
  echo "  ok   $mode installs idempotently"
done
printf 'stale guard\n' > "$GUARD"
site_identity_guard_sync
cmp "$SCRIPT_DIR/templates/wp-coding-agents-site-identity-guard.php" "$GUARD"
rm "$GUARD"
DRY_RUN=true site_identity_guard_sync
[ ! -f "$GUARD" ]
site_identity_guard_sync

for context in cli rest admin constant; do
  CONTEXT="$context" php -r '
function add_filter($h, $c, $p=10, $a=1) { $GLOBALS["hooks"][$h][]=$c; }
function add_action($h, $c, $p=10, $a=1) { add_filter($h,$c,$p,$a); }
function apply_filters($h, $v, ...$args) {
  foreach ($GLOBALS["hooks"][$h] ?? [] as $c) { $v=$c($v,...$args); }
  return $v;
}
function ensure($ok, $message) { if (!$ok) { fwrite(STDERR,$message."\n"); exit(1); } }
class WP_CLI { static function error($m) { throw new RuntimeException($m); } }
class WP_Error {
  function __construct(public $code, public $message, public $data) {}
}
function wp_die($error, $title="", $args=[]) {
  ensure($error instanceof WP_Error && $error->data["status"] === 403 && $args["response"] === 403, "REST must return 403");
  throw new RuntimeException($error->message);
}
define("ABSPATH", "/");
$context=getenv("CONTEXT");
if ($context === "cli" || $context === "constant") { define("WP_CLI",true); }
if ($context === "rest") { define("REST_REQUEST",true); }
if ($context === "constant") { define("WP_CODING_AGENTS_ALLOW_SITE_IDENTITY_CHANGE",true); }
require getenv("GUARD");
// A normal plugin can extend the guarded list before plugins_loaded.
add_filter("wp_coding_agents_site_identity_guarded_options", function($options) { $options[]="custom_identity"; return $options; });
ensure(!empty($GLOBALS["hooks"]["plugins_loaded"]), "registration not hooked");
foreach ($GLOBALS["hooks"]["plugins_loaded"] as $callback) { $callback(); }
foreach (["stylesheet","template","show_on_front","page_on_front","page_for_posts","blogname","custom_identity"] as $option) {
  $hook="pre_update_option_".$option;
  ensure(!empty($GLOBALS["hooks"][$hook]), "option not hooked: ".$option);
  ensure(apply_filters($hook,"old","old",$option) === "old", "unchanged value refused");
  try {
    $value=apply_filters($hook,"new","old",$option);
    ensure($context === "admin" || $context === "constant", "automated change not refused: ".$option);
    ensure($value === "new", "allowed change lost");
  } catch (RuntimeException $e) {
    ensure($context === "cli" || $context === "rest", "interactive or opted-in change refused");
    ensure(str_contains($e->getMessage(),$option) && str_contains($e->getMessage(),"WP_CODING_AGENTS_ALLOW_SITE_IDENTITY_CHANGE=1"), "refusal must name option and opt-in");
  }
  putenv("WP_CODING_AGENTS_ALLOW_SITE_IDENTITY_CHANGE=1");
  ensure(apply_filters($hook,"new","old",$option) === "new", "env opt-in refused");
  putenv("WP_CODING_AGENTS_ALLOW_SITE_IDENTITY_CHANGE");
}
ensure(apply_filters("pre_update_option_unrelated","new","old","unrelated") === "new", "unrelated option refused");
'
  echo "  ok   $context behaviour"
done

echo "OK: site identity guard assertions passed"
