<?php

// Narrow MIT-owned harness for WP-CLI dispatch and DMC command-class loading.
// This deliberately does not bootstrap WordPress or either plugin.

define('WP_CLI', true);
define('ABSPATH', __DIR__ . '/');
$workspace_path = getenv('DMC_WORKSPACE_PATH');
if (is_string($workspace_path) && '' !== $workspace_path) {
	define('DATAMACHINE_WORKSPACE_PATH', $workspace_path);
}
$wp_cli_phar = getenv('WP_CLI_PHAR');
define('WP_CLI_ROOT', 'phar://' . $wp_cli_phar . '/vendor/wp-cli/wp-cli');
define('WP_CLI_VENDOR_DIR', 'phar://' . $wp_cli_phar . '/vendor');
require WP_CLI_ROOT . '/php/fallback-functions.php';
require WP_CLI_ROOT . '/php/utils.php';
require WP_CLI_ROOT . '/php/dispatcher.php';
require WP_CLI_ROOT . '/php/class-wp-cli.php';
require WP_CLI_ROOT . '/php/class-wp-cli-command.php';
require 'phar://' . $wp_cli_phar . '/vendor/autoload.php';
WP_CLI::set_logger(new WP_CLI\Loggers\Regular(false));
$runner = WP_CLI::get_runner();
$runner_config = new ReflectionProperty($runner, 'config');
$runner_config->setValue($runner, array('debug' => false, 'quiet' => false, 'prompt' => false));

final class WP_Error {
	public function __construct(public string $code, public string $message, public array $data = array()) {}
	public function get_error_code(): string { return $this->code; }
	public function get_error_message(): string { return $this->message; }
	public function get_error_data(): array { return $this->data; }
}

function is_wp_error(mixed $value): bool { return $value instanceof WP_Error; }
function wp_json_encode(mixed $value, int $flags = 0): string|false { return json_encode($value, $flags); }

$GLOBALS['test_actions'] = array();
$GLOBALS['test_filters'] = array();
function add_action(string $hook, callable $callback, int $priority = 10, int $accepted_args = 1): void {
	$GLOBALS['test_actions'][$hook][$priority][] = $callback;
}
function add_filter(string $hook, callable $callback, int $priority = 10, int $accepted_args = 1): void {
	$GLOBALS['test_filters'][$hook][$priority][] = $callback;
}

function datamachine_code_finish_bounded_workspace_cli_request(): void {
	if (false !== getenv('DMC_FINALIZER_LOG')) {
		file_put_contents(getenv('DMC_FINALIZER_LOG'), "finalized\n", FILE_APPEND);
	}
}

final class DMC_Test_Ability {
	public function execute(array $input): array|WP_Error {
		return ($GLOBALS['dmc_test_ability_callback'])($input);
	}
}
function wp_get_ability(string $name): ?DMC_Test_Ability {
	return 'datamachine-code/workspace-worktree-add' === $name ? new DMC_Test_Ability() : null;
}

eval('namespace DataMachine\\Cli; class BaseCommand extends \\WP_CLI_Command {}');
$version_skew = getenv('DMC_VERSION_SKEW');
if (false !== $version_skew && '' !== $version_skew) {
	$valid_definition = "array('add' => array('shortdesc' => 'Add.', 'longdesc' => 'Add.', 'synopsis' => array(array('type' => 'positional', 'name' => 'repo', 'required' => true), array('type' => 'positional', 'name' => 'branch', 'required' => true), array('type' => 'flag', 'name' => 'skip-context-injection', 'optional' => true), array('type' => 'flag', 'name' => 'skip-bootstrap', 'optional' => true))))";
	$definition = 'definition' === $version_skew
		? "array('add' => array('shortdesc' => 'Add.', 'longdesc' => 'Add.', 'synopsis' => array(array('type' => 'positional', 'name' => 'repo', 'required' => true), array('type' => 'positional', 'name' => 'branch', 'optional' => true), array('type' => 'flag', 'name' => 'skip-context-injection', 'optional' => true), array('type' => 'flag', 'name' => 'skip-bootstrap', 'optional' => true))))"
		: $valid_definition;
	$dispatcher = match ($version_skew) {
		'arity'  => 'public function __worktree_operation(string $operation, array $args): void {}',
		'types'  => 'public function __worktree_operation(array $operation, array $args, array $assoc_args): void {}',
		'return' => 'public function __worktree_operation(string $operation, array $args, array $assoc_args): array { return array(); }',
		default  => 'public function __worktree_operation(string $operation, array $args, array $assoc_args): void {}',
	};
	eval("namespace DataMachineCode\\Cli\\Commands; class WorkspaceCommand extends \\DataMachine\\Cli\\BaseCommand { public static function worktree_command_definitions(): array { return {$definition}; } {$dispatcher} }");
} else {
	$fixture_root = getenv('DMC_FIXTURE_ROOT');
	if (!is_string($fixture_root) || !is_dir($fixture_root)) {
		throw new RuntimeException('DMC_FIXTURE_ROOT must identify the verified, extracted DMC source.');
	}
	require $fixture_root . '/inc/Workspace/WorktreeContextInjector.php';
	require $fixture_root . '/inc/Cli/CliResponseRenderer.php';
	require $fixture_root . '/inc/Cli/Commands/WorkspaceCommand.php';
}

require getenv('HOMEBOY_ADAPTER_PATH');
$ability_args = array('execute_callback' => static fn(array $input): array => $input, 'meta' => array());
foreach ($GLOBALS['test_filters']['datamachine_code_ability_registration_args'] ?? array() as $callbacks) {
	foreach ($callbacks as $callback) {
		$ability_args = $callback($ability_args, 'datamachine-code/workspace-worktree-add');
	}
}
$GLOBALS['dmc_test_ability_callback'] = $ability_args['execute_callback'];

add_action(
	'plugins_loaded',
	static function (): void {
		$namespace = '';
		foreach (array('datamachine-code', 'workspace', 'worktree') as $part) {
			$namespace = ltrim($namespace . ' ' . $part);
			WP_CLI::add_command($namespace, WP_CLI\Dispatcher\CommandNamespace::class);
		}
		if (false !== getenv('DMC_VERSION_SKEW') && '' !== getenv('DMC_VERSION_SKEW')) {
			WP_CLI::add_command(
				'datamachine-code workspace worktree add',
				static function (): void { WP_CLI::line('native-version-skew-command'); },
				array('synopsis' => '<repo> <branch>')
			);
			return;
		}

		WP_CLI::add_command(
			'datamachine-code workspace worktree add',
			static function (): void { throw new RuntimeException('The adapter did not replace the test leaf.'); },
			array('after_invoke' => 'datamachine_code_finish_bounded_workspace_cli_request')
		);
	},
	21
);

ksort($GLOBALS['test_actions']['plugins_loaded']);
foreach ($GLOBALS['test_actions']['plugins_loaded'] as $callbacks) {
	foreach ($callbacks as $callback) {
		$callback();
	}
}

$path = array('datamachine-code', 'workspace', 'worktree', 'add');
$command = WP_CLI::get_root_command();
foreach ($path as $part) {
	$lookup = array($part);
	$command = $command->find_subcommand($lookup);
	if (!$command) {
		break;
	}
}
if (!$command instanceof WP_CLI\Dispatcher\Subcommand) {
	throw new RuntimeException('The worktree add command was not registered as a WP-CLI leaf: ' . get_debug_type($command));
}
if ('--dispatcher-help' === ($argv[1] ?? '')) {
	echo wp_json_encode(array('synopsis' => $command->get_synopsis(), 'longdesc' => $command->get_longdesc())), "\n";
	exit;
}

$tokens = array_slice($argv, 1);
if (array_slice($tokens, 0, 4) !== $path) {
	throw new RuntimeException('Unexpected command route.');
}
$args = array();
$assoc_args = array();
foreach (array_slice($tokens, 4) as $token) {
	if (!str_starts_with($token, '--')) {
		$args[] = $token;
		continue;
	}
	[$key, $value] = array_pad(explode('=', substr($token, 2), 2), 2, true);
	$assoc_args[$key] = $value;
}
$command->invoke($args, $assoc_args, array());
