<?php

declare(strict_types=1);

define('ABSPATH', __DIR__);
define('WP_CONTENT_DIR', __DIR__);

$GLOBALS['wp_coding_agents_test_filters'] = array();
function add_filter(string $hook, callable $callback, int $priority = 10): void {
	$GLOBALS['wp_coding_agents_test_filters'][$hook][$priority][] = $callback;
}

function apply_filters(string $hook, $value) {
	$filters = $GLOBALS['wp_coding_agents_test_filters'][$hook] ?? array();
	ksort($filters);
	foreach ($filters as $callbacks) {
		foreach ($callbacks as $callback) {
			$value = $callback($value);
		}
	}
	return $value;
}

require_once dirname(__DIR__) . '/carried-plugins/wp-coding-agents-integration/wp-coding-agents-integration.php';

use WpCodingAgents\Integration\HostCapabilities;

assert(class_exists(HostCapabilities::class));
assert(isset($GLOBALS['wp_coding_agents_test_filters']['wp_coding_agents_host_can_execute_processes']));
assert(isset($GLOBALS['wp_coding_agents_test_filters']['wp_coding_agents_host_has_writable_process_workspace']));
assert(isset($GLOBALS['wp_coding_agents_test_filters']['intelligence_host_has_shell']));
assert(isset($GLOBALS['wp_coding_agents_test_filters']['intelligence_host_has_writable_content_directory']));
assert(
	'WpCodingAgents\\Integration\\provide_process_execution_capability'
	=== $GLOBALS['wp_coding_agents_test_filters']['wp_coding_agents_host_can_execute_processes'][10][0]
);
assert(
	'WpCodingAgents\\Integration\\provide_writable_process_workspace_capability'
	=== $GLOBALS['wp_coding_agents_test_filters']['wp_coding_agents_host_has_writable_process_workspace'][10][0]
);
assert(
	'WpCodingAgents\\Integration\\provide_intelligence_shell_capability'
	=== $GLOBALS['wp_coding_agents_test_filters']['intelligence_host_has_shell'][10][0]
);
assert(true === apply_filters('intelligence_host_has_shell', true));
assert(true === apply_filters('intelligence_host_has_writable_content_directory', false));

assert(HostCapabilities::can_execute_processes() === apply_filters('wp_coding_agents_host_can_execute_processes', false));
assert(HostCapabilities::has_writable_content_directory() === apply_filters('wp_coding_agents_host_has_writable_process_workspace', false));
assert(HostCapabilities::has_shell() === apply_filters('intelligence_host_has_shell', false));
assert(HostCapabilities::has_writable_content_directory() === apply_filters('intelligence_host_has_writable_content_directory', false));

$required_functions = array('exec', 'shell_exec', 'proc_open', 'proc_get_status', 'proc_close', 'proc_terminate', 'posix_kill');
$available = static fn(string $function_name): bool => in_array($function_name, $required_functions, true);
$success = static fn(string $command): array => array(
	'output' => array('__wp_coding_agents_shell_ok__'),
	'exit_code' => 0,
);

$diagnostic = HostCapabilities::evaluate_shell_capability($available, '', $success);
assert(true === $diagnostic['ok']);
assert(true === $diagnostic['proc_open_available']);
assert(true === HostCapabilities::has_writable_content_directory());

$process = HostCapabilities::evaluate_process_capability($available, '', $success, static fn(): bool => true);
assert(true === $process['ok']);
assert('ok' === $process['reason']);

foreach ($required_functions as $function_name) {
	$disabled_process = HostCapabilities::evaluate_process_capability($available, $function_name, $success, static fn(): bool => true);
	assert(false === $disabled_process['ok']);
	assert($function_name . '_disabled' === $disabled_process['reason']);

	$missing_process = HostCapabilities::evaluate_process_capability(
		static fn(string $candidate): bool => $candidate !== $function_name && $available($candidate),
		'',
		$success,
		static fn(): bool => true
	);
	assert(false === $missing_process['ok']);
	assert($function_name . '_missing' === $missing_process['reason']);
}

$missing_launcher = HostCapabilities::evaluate_process_capability($available, '', $success, static fn(): bool => false);
assert(false === $missing_launcher['ok']);
assert('setsid_missing' === $missing_launcher['reason']);

$disabled = HostCapabilities::evaluate_shell_capability($available, 'shell_exec', $success);
assert(false === $disabled['ok']);
assert('shell_exec_disabled' === $disabled['reason']);

$failed = HostCapabilities::evaluate_shell_capability(
	$available,
	'',
	static fn(string $command): array => array('output' => array('wrong'), 'exit_code' => 0)
);
assert(false === $failed['ok']);
assert('probe_failed' === $failed['reason']);

assert(
	HostCapabilities::can_execute_processes()
	=== apply_filters('wp_coding_agents_host_can_execute_processes', true)
);
add_filter('wp_coding_agents_host_can_execute_processes', static fn(bool $available): bool => false, 20);
assert(false === apply_filters('wp_coding_agents_host_can_execute_processes', true));
assert(true === apply_filters('wp_coding_agents_host_has_writable_process_workspace', true));

echo "PASS: focused WordPress integration host capabilities\n";
