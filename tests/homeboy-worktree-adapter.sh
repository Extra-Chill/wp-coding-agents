#!/bin/bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/homeboy.sh"

SITE_PATH="$TMP/site"
FAKE_BIN="$TMP/bin"
LOG="$TMP/homeboy.log"
mkdir -p "$SITE_PATH/wp-content/mu-plugins" "$FAKE_BIN"

cat > "$FAKE_BIN/homeboy" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HOMEBOY_ADAPTER_TEST_LOG"
case "$*" in
  "config show /worktree_providers/dmc"|"config show /worktree_providers/wpca-retention-probe"|"config show /worktree_providers/wpca-task-attachment-probe")
    pointer="${*:3}"
    state="$HOMEBOY_PROVIDER_STATE-$(printf '%s' "$pointer" | tr '/-' '__')"
    [ -f "$state" ] || exit 1
    printf '%s\n' '{"schema":"homeboy/command-result/v3","success":true,"data":{"value":{"kind":"command"}}}'
    ;;
  "config show /settings/worktree_provider_lifecycle/dmc")
    [ -f "$HOMEBOY_FINALIZER_STATE" ] || exit 1
    printf '%s\n' '{"schema":"homeboy/command-result/v3","success":true,"data":{"value":{"finalize":["legacy"]}}}'
    ;;
  "config remove /worktree_providers/dmc"|"config remove /worktree_providers/wpca-retention-probe"|"config remove /worktree_providers/wpca-task-attachment-probe")
    pointer="${*:3}"
    state="$HOMEBOY_PROVIDER_STATE-$(printf '%s' "$pointer" | tr '/-' '__')"
    rm -f "$state"
    printf '%s\n' '{"schema":"homeboy/command-result/v3","success":true,"data":{}}'
    ;;
  "config remove /settings/worktree_provider_lifecycle/dmc")
    rm -f "$HOMEBOY_FINALIZER_STATE"
    printf '%s\n' '{"schema":"homeboy/command-result/v3","success":true,"data":{}}'
    ;;
  "worktree create "*)
    printf '%s\n' '{"schema":"homeboy/command-result/v3","success":true,"data":{"action":"create","record":{"id":"fixture@fix-474","component_id":"fixture","worktree_path":"/workspace/fixture@fix-474","branch":"fix/474","base_ref":"origin/main","task_url":"https://example.test/474","run_id":"run-474","cleanup_policy":"remove_when_safe","created_at":"2026-08-30T00:00:00Z","state":"active"}}}'
    ;;
  "worktree list")
    printf '%s\n' '{"schema":"homeboy/command-result/v3","success":true,"data":{"action":"list","worktrees":[{"id":"fixture@fix-474","component_id":"fixture","worktree_path":"/workspace/fixture@fix-474","branch":"fix/474","base_ref":"origin/main","task_url":"https://example.test/474","run_id":"run-474","created_at":"2026-08-30T00:00:00Z","state":"active"},{"id":"fixture@removed","component_id":"fixture","worktree_path":"/workspace/fixture@removed","branch":"removed","state":"removed"}]}}'
    ;;
  "worktree status "*)
    printf '%s\n' '{"schema":"homeboy/command-result/v3","success":true,"data":{"action":"status","record":{"id":"fixture@fix-474","component_id":"fixture","worktree_path":"/workspace/fixture@fix-474","branch":"fix/474","run_id":"run-474","state":"active"},"safety":{"dirty":false,"safe":true,"primary_checkout":false,"unpushed_commits":0}}}'
    ;;
  "worktree finalize "*)
    printf '%s\n' '{"schema":"homeboy/command-result/v3","success":true,"data":{"action":"finalize","provider_id":"builtin","handle":"fixture@fix-474","disposition":"succeeded","owner_outcome":"success","lifecycle_state":"completed","inspection_path":"/workspace/fixture@fix-474"}}'
    ;;
  "worktree cleanup"|"worktree cleanup --apply"|"worktree cleanup --force"|"worktree cleanup --apply --force")
    dry_run=true
    case "$*" in *--apply*) dry_run=false ;; esac
    printf '{"schema":"homeboy/command-result/v3","success":true,"data":{"action":"cleanup","worktrees":{"dry_run":%s,"counts":{"candidates":1},"candidates":[{"id":"fixture@fix-474"}],"removed":[],"skipped":[]}}}\n' "$dry_run"
    ;;
  "worktree remove "*)
    printf '%s\n' '{"schema":"homeboy/command-result/v3","success":true,"data":{"action":"remove","record":{"id":"fixture@fix-474","state":"removed"}}}'
    ;;
  *)
    printf '%s\n' '{"schema":"homeboy/command-result/v3","success":false,"error":{"message":"unexpected fixture command"}}'
    exit 1
    ;;
esac
SH
chmod +x "$FAKE_BIN/homeboy"

PATH="$FAKE_BIN:$PATH"
export PATH HOMEBOY_ADAPTER_TEST_LOG="$LOG"
export HOMEBOY_PROVIDER_STATE="$TMP/provider-state" HOMEBOY_FINALIZER_STATE="$TMP/finalizer-state"
provider_state() { printf '%s-%s' "$HOMEBOY_PROVIDER_STATE" "$(printf '%s' "$1" | tr '/-' '__')"; }
UPDATED_ITEMS=()
DRY_RUN=false
BLUE=""
NC=""
service_file_normalize_perms() { chmod 0664 "$1"; }
homeboy_worktree_adapter_sync
ADAPTER="$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-homeboy-worktrees.php"
php -l "$ADAPTER" >/dev/null

cat > "$TMP/adapter-harness.php" <<'PHP'
<?php
define('ABSPATH', __DIR__);

final class WP_Error {
	public function __construct(public string $code, public string $message, public array $data = array()) {}
}
function is_wp_error(mixed $value): bool { return $value instanceof WP_Error; }
$filters = array();
function add_filter(string $hook, callable $callback, int $priority = 10, int $accepted_args = 1): void {
	global $filters;
	$filters[$hook] = $callback;
}
function expect(bool $condition, string $message): void {
	if (!$condition) {
		fwrite(STDERR, "FAIL: {$message}\n");
		exit(1);
	}
}

require $argv[1];
$callback = $filters['datamachine_code_ability_registration_args'] ?? null;
expect(is_callable($callback), 'adapter filter registered');
$untouched = $callback(array('execute_callback' => 'original'), 'datamachine-code/workspace-show');
expect('original' === $untouched['execute_callback'], 'non-worktree ability remains unchanged');

$ability = static function (string $slug) use ($callback): callable {
	$args = $callback(array('execute_callback' => 'dmc', 'meta' => array('show_in_rest' => false)), $slug);
	expect('homeboy' === ($args['meta']['worktree_lifecycle_owner'] ?? null), "{$slug} declares Homeboy ownership");
	expect(is_callable($args['execute_callback']), "{$slug} callback replaced");
	return $args['execute_callback'];
};

$add = $ability('datamachine-code/workspace-worktree-add');
$created = $add(array('repo' => 'fixture', 'branch' => 'fix/474', 'from' => 'origin/main', 'task_url' => 'https://example.test/474', 'owner_run_ref' => 'run-474', 'cleanup_policy' => 'remove_on_success'));
expect(!is_wp_error($created) && 'fixture@fix-474' === $created['handle'], 'create projects native Homeboy record');
$manual = $add(array('repo' => 'fixture', 'branch' => 'fix/474-manual', 'cleanup_policy' => 'manual'));
expect(!is_wp_error($manual), 'manual lifecycle intent maps to non-cleanup-eligible Homeboy policy');
expect(is_wp_error($add(array('repo' => 'fixture', 'branch' => 'unsupported', 'bootstrap' => true))), 'explicit DMC-only create behavior returns typed refusal');

$list = $ability('datamachine-code/workspace-worktree-list');
$listed = $list(array('handle' => 'fixture@fix-474', 'include_status' => true, 'limit' => 1));
expect(!is_wp_error($listed) && 1 === $listed['returned'], 'exact list returns one Homeboy record');
expect(0 === $listed['worktrees'][0]['dirty'], 'status safety projects into canonical dirty count');
$all = $list(array('all' => true));
expect(1 === $all['returned'] && 'fixture@fix-474' === $all['worktrees'][0]['handle'], 'removed Homeboy records do not reappear through DMC inventory');

$finalize = $ability('datamachine-code/workspace-worktree-finalize');
$finalized = $finalize(array('handle' => 'fixture@fix-474', 'state' => 'merged'));
expect(!is_wp_error($finalized) && 'merged' === $finalized['lifecycle_state'], 'terminal finalization preserves the canonical DMC state');
expect(is_wp_error($finalize(array('handle' => 'fixture@fix-474', 'state' => 'active'))), 'nonterminal finalization is refused');

$cleanup = $ability('datamachine-code/workspace-worktree-cleanup');
expect(true === $cleanup(array('dry_run' => true))['dry_run'], 'cleanup preview remains non-mutating');
expect(false === $cleanup(array('dry_run' => false))['dry_run'], 'cleanup apply uses Homeboy apply mode');
expect(false === $cleanup(array())['dry_run'], 'canonical cleanup default remains apply mode');
expect(false === $cleanup(array('force' => true))['dry_run'], 'cleanup force remains Homeboy-owned and explicit');

$remove = $ability('datamachine-code/workspace-worktree-remove');
expect(true === $remove(array('repo' => 'fixture', 'branch' => 'fix/474'))['success'], 'remove uses Homeboy safety path');

$unsupported = $ability('datamachine-code/workspace-worktree-reconcile-metadata');
$refusal = $unsupported(array());
expect(is_wp_error($refusal) && 'wp_coding_agents_homeboy_worktree_unsupported' === $refusal->code, 'DMC-only operation returns typed refusal');
PHP
php "$TMP/adapter-harness.php" "$ADAPTER"

if grep -q 'datamachine-code' "$LOG"; then
  echo "FAIL: adapter re-entered DMC worktree commands" >&2
  cat "$LOG" >&2
  exit 1
fi
grep -q '^worktree create fixture ' "$LOG"
grep -q '^worktree create fixture --branch fix/474-manual --from origin/HEAD --cleanup-policy preserve-on-failure$' "$LOG"
grep -q '^worktree finalize fixture@fix-474 --owner-run-ref run-474 --disposition succeeded$' "$LOG"
grep -q '^worktree cleanup --apply$' "$LOG"

DRY_RUN=true
configure_homeboy_worktree_ownership > "$TMP/dry-run.log"
grep -q 'homeboy config remove /worktree_providers/dmc' "$TMP/dry-run.log"
grep -q 'homeboy config remove /worktree_providers/wpca-retention-probe' "$TMP/dry-run.log"
grep -q 'homeboy config remove /worktree_providers/wpca-task-attachment-probe' "$TMP/dry-run.log"
grep -q 'homeboy config remove /settings/worktree_provider_lifecycle/dmc' "$TMP/dry-run.log"

touch "$(provider_state /worktree_providers/dmc)" "$(provider_state /worktree_providers/wpca-retention-probe)" "$(provider_state /worktree_providers/wpca-task-attachment-probe)" "$HOMEBOY_FINALIZER_STATE"
DRY_RUN=false
configure_homeboy_worktree_ownership > "$TMP/apply.log"
for pointer in /worktree_providers/dmc /worktree_providers/wpca-retention-probe /worktree_providers/wpca-task-attachment-probe; do
  [ ! -e "$(provider_state "$pointer")" ] || { echo "FAIL: legacy provider $pointer remained configured" >&2; exit 1; }
done
[ ! -e "$HOMEBOY_FINALIZER_STATE" ] || { echo "FAIL: legacy DMC finalizer remained configured" >&2; exit 1; }

echo "OK: DMC worktree abilities use Homeboy without circular provider ownership"
