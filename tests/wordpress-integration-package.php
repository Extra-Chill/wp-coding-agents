<?php

declare(strict_types=1);

define('ABSPATH', __DIR__);
define('WP_CONTENT_DIR', __DIR__);

require_once dirname(__DIR__) . '/carried-plugins/wp-coding-agents-integration/wp-coding-agents-integration.php';

use WpCodingAgents\Integration\HostCapabilities;

assert(class_exists(HostCapabilities::class));

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
