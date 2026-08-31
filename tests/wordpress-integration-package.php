<?php

declare(strict_types=1);

define('ABSPATH', __DIR__);
define('WP_CONTENT_DIR', __DIR__);

$GLOBALS['wp_coding_agents_test_filters'] = array();
function add_filter(string $hook, callable $callback): void {
	$GLOBALS['wp_coding_agents_test_filters'][$hook][] = $callback;
}

function apply_filters(string $hook, $value) {
	foreach ($GLOBALS['wp_coding_agents_test_filters'][$hook] ?? array() as $callback) {
		$value = $callback($value);
	}
	return $value;
}

require_once dirname(__DIR__) . '/carried-plugins/wp-coding-agents-integration/wp-coding-agents-integration.php';

use WpCodingAgents\Integration\HostCapabilities;

assert(class_exists(HostCapabilities::class));
assert(isset($GLOBALS['wp_coding_agents_test_filters']['intelligence_host_has_shell']));
assert(isset($GLOBALS['wp_coding_agents_test_filters']['intelligence_host_has_writable_content_directory']));
assert(
	'WpCodingAgents\\Integration\\provide_intelligence_shell_capability'
	=== $GLOBALS['wp_coding_agents_test_filters']['intelligence_host_has_shell'][0]
);
assert(true === apply_filters('intelligence_host_has_shell', true));
assert(true === apply_filters('intelligence_host_has_writable_content_directory', false));

// Host integrations declare these independently; no declaration is support.
assert(false === apply_filters('wp_coding_agents_host_can_execute_processes', false));
assert(false === apply_filters('wp_coding_agents_host_has_writable_process_workspace', false));
add_filter('wp_coding_agents_host_can_execute_processes', static fn(bool $available): bool => false);
add_filter('wp_coding_agents_host_has_writable_process_workspace', static fn(bool $available): bool => false);
assert(false === apply_filters('wp_coding_agents_host_can_execute_processes', false));
assert(false === apply_filters('wp_coding_agents_host_has_writable_process_workspace', false));
$GLOBALS['wp_coding_agents_test_filters']['wp_coding_agents_host_can_execute_processes'] = array();
$GLOBALS['wp_coding_agents_test_filters']['wp_coding_agents_host_has_writable_process_workspace'] = array();
add_filter('wp_coding_agents_host_can_execute_processes', static fn(bool $available): bool => true);
add_filter('wp_coding_agents_host_has_writable_process_workspace', static fn(bool $available): bool => true);
assert(true === apply_filters('wp_coding_agents_host_can_execute_processes', false));
assert(true === apply_filters('wp_coding_agents_host_has_writable_process_workspace', false));

$available = static fn(string $function_name): bool => in_array($function_name, array('exec', 'shell_exec', 'proc_open'), true);
$success = static fn(string $command): array => array(
	'output' => array('__wp_coding_agents_shell_ok__'),
	'exit_code' => 0,
);

$diagnostic = HostCapabilities::evaluate_shell_capability($available, '', $success);
assert(true === $diagnostic['ok']);
assert(true === $diagnostic['proc_open_available']);
assert(true === HostCapabilities::has_writable_content_directory());

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

echo "PASS: focused WordPress integration host capabilities\n";
