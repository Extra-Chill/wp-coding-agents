<?php
/**
 * Pure-PHP smoke test for the wp-coding-agents CLI transport runtime.
 *
 *   php tests/smoke-cli-transport.php
 *
 * @package wp-coding-agents
 */

declare( strict_types=1 );

if ( ! defined( 'ABSPATH' ) ) {
	define( 'ABSPATH', __DIR__ . '/' );
}

if ( ! class_exists( 'WP_Error' ) ) {
	class WP_Error {
		public function __construct( private string $code = '', private string $message = '', private mixed $data = null ) {}

		public function get_error_code(): string {
			return $this->code;
		}

		public function get_error_message(): string {
			return $this->message;
		}

		public function get_error_data(): mixed {
			return $this->data;
		}
	}
}

if ( ! function_exists( 'add_filter' ) ) {
	function add_filter( string $hook, callable $callback, int $priority = 10, int $accepted_args = 1 ): void {
		global $wp_coding_agents_test_filters;
		$wp_coding_agents_test_filters[ $hook ][ $priority ][] = $callback;
		unset( $accepted_args );
	}
}

if ( ! function_exists( 'apply_filters' ) ) {
	function apply_filters( string $hook, mixed $value, ...$args ): mixed {
		global $wp_coding_agents_test_filters;
		if ( empty( $wp_coding_agents_test_filters[ $hook ] ) ) {
			return $value;
		}

		ksort( $wp_coding_agents_test_filters[ $hook ] );
		foreach ( $wp_coding_agents_test_filters[ $hook ] as $callbacks ) {
			foreach ( $callbacks as $callback ) {
				$value = $callback( $value, ...$args );
			}
		}

		return $value;
	}
}

if ( ! function_exists( 'get_option' ) ) {
	function get_option( string $key, mixed $default_value = false ): mixed {
		global $wp_coding_agents_test_options;
		return $wp_coding_agents_test_options[ $key ] ?? $default_value;
	}
}

require __DIR__ . '/../templates/wp-coding-agents-cli-transport.php';

$failures = array();
$assert   = static function ( string $label, bool $condition ) use ( &$failures ): void {
	if ( $condition ) {
		echo "  [PASS] {$label}\n";
		return;
	}

	$failures[] = $label;
	echo "  [FAIL] {$label}\n";
};

echo "=== smoke-cli-transport ===\n";

$find_stub = static function ( array $candidates ): ?string {
	foreach ( $candidates as $candidate ) {
		if ( is_executable( $candidate ) ) {
			return $candidate;
		}
	}
	return null;
};

$echo_bin  = $find_stub( array( '/bin/echo', '/usr/bin/echo' ) );
$env_bin   = $find_stub( array( '/usr/bin/env', '/bin/env' ) );
$true_bin  = $find_stub( array( '/bin/true', '/usr/bin/true' ) );
$false_bin = $find_stub( array( '/bin/false', '/usr/bin/false' ) );
$sleep_bin = $find_stub( array( '/bin/sleep', '/usr/bin/sleep' ) );
foreach ( array( 'echo' => $echo_bin, 'env' => $env_bin, 'true' => $true_bin, 'false' => $false_bin, 'sleep' => $sleep_bin ) as $name => $path ) {
	if ( null === $path ) {
		echo "  [SKIP] stub binary {$name} not present\n";
		exit( 0 );
	}
}

global $wp_coding_agents_test_options, $wp_coding_agents_test_filters;
$wp_coding_agents_test_options = array();

$valid_entry = array(
	'command' => $echo_bin,
	'args'    => array( '--', '{recipient}', '{message}' ),
	'detach'  => false,
	'timeout' => 5,
);
$normalized  = WpCodingAgents_Cli_Channel_Registry::normalize_entry( $valid_entry );
$assert( 'valid entry normalizes', is_array( $normalized ) && $echo_bin === $normalized['command'] );
$assert( 'missing command is rejected', null === WpCodingAgents_Cli_Channel_Registry::normalize_entry( array( 'args' => array() ) ) );
$assert( 'non-string arg is rejected', null === WpCodingAgents_Cli_Channel_Registry::normalize_entry( array( 'command' => $echo_bin, 'args' => array( 123 ) ) ) );

$wp_coding_agents_test_options['datamachine_code_cli_channels'] = array(
	'legacy-option' => array(
		'command' => $echo_bin,
		'args'    => array( 'legacy-option' ),
	),
	'collision'     => array(
		'command' => $echo_bin,
		'args'    => array( 'legacy' ),
	),
);
$wp_coding_agents_test_options['wp_coding_agents_cli_channels'] = array(
	'new-option' => array(
		'command' => $echo_bin,
		'args'    => array( 'new-option' ),
	),
	'collision'  => array(
		'command' => $echo_bin,
		'args'    => array( 'new' ),
	),
);

add_filter(
	'datamachine_code_cli_channels',
	static function ( array $channels ) use ( $echo_bin ): array {
		$channels['legacy-filter'] = array(
			'command' => $echo_bin,
			'args'    => array( 'legacy-filter' ),
		);
		return $channels;
	}
);
add_filter(
	'wp_coding_agents_cli_channels',
	static function ( array $channels ) use ( $echo_bin ): array {
		$channels['new-filter'] = array(
			'command' => $echo_bin,
			'args'    => array( 'new-filter' ),
		);
		return $channels;
	}
);

$channels = WpCodingAgents_Cli_Channel_Registry::get_channels();
$assert( 'legacy option channel is present', isset( $channels['legacy-option'] ) );
$assert( 'new option channel is present', isset( $channels['new-option'] ) );
$assert( 'legacy filter channel is present', isset( $channels['legacy-filter'] ) );
$assert( 'new filter channel is present', isset( $channels['new-filter'] ) );
$assert( 'new registry wins collisions', isset( $channels['collision']['args'][0] ) && 'new' === $channels['collision']['args'][0] );

$substituted = WpCodingAgents_Cli_Channel_Registry::substitute_tokens(
	array( '--to', '{recipient}', '--msg', '{message}', '--conv', '{conversation_id}', '--ch', '{channel}' ),
	array(
		'recipient'       => 'user-123',
		'message'         => 'hello $(rm -rf /)',
		'conversation_id' => 'conv-abc',
		'channel'         => 'fixture-channel',
	)
);
$assert( 'message token substituted verbatim', 'hello $(rm -rf /)' === $substituted[3] );
$assert( 'conversation token substituted', 'conv-abc' === $substituted[5] );

$wp_coding_agents_test_options = array(
	'wp_coding_agents_cli_channels' => array(
		'sync-echo'     => array(
			'command' => $echo_bin,
			'args'    => array( '{recipient}:{message}' ),
			'detach'  => false,
			'timeout' => 5,
		),
		'sync-true'     => array(
			'command' => $true_bin,
			'args'    => array(),
			'detach'  => false,
			'timeout' => 5,
		),
		'sync-false'    => array(
			'command' => $false_bin,
			'args'    => array(),
			'detach'  => false,
			'timeout' => 5,
		),
		'sync-sleep'    => array(
			'command' => $sleep_bin,
			'args'    => array( '5' ),
			'detach'  => false,
			'timeout' => 1,
		),
		'detached-true' => array(
			'command' => $true_bin,
			'args'    => array(),
			'detach'  => true,
		),
		'detached-false' => array(
			'command' => $false_bin,
			'args'    => array(),
			'detach'  => true,
		),
		'inherit-env'   => array(
			'command' => $env_bin,
			'args'    => array(),
			'detach'  => false,
			'timeout' => 5,
		),
		'configured-env' => array(
			'command' => $env_bin,
			'args'    => array(),
			'detach'  => false,
			'timeout' => 5,
			'env'     => array(
				'WP_CODING_AGENTS_CONFIGURED_ENV' => 'configured-ok',
			),
		),
		// #228: a channel with no configured HOME must not have a poisoned
		// (unwritable) inherited HOME leak through to the child.
		'guard-home'    => array(
			'command' => $env_bin,
			'args'    => array(),
			'detach'  => false,
			'timeout' => 5,
		),
		// #228: a channel that pins a writable HOME keeps it verbatim.
		'pinned-home'   => array(
			'command' => $env_bin,
			'args'    => array(),
			'detach'  => false,
			'timeout' => 5,
			'env'     => array(
				'HOME' => sys_get_temp_dir(),
			),
		),
	),
);

$claim_known = WpCodingAgents_Cli_Channel_Transport::maybe_claim( null, array( 'channel' => 'sync-true' ) );
$assert( 'claims registered channel', is_callable( $claim_known ) );
$assert( 'declines unknown channel', null === WpCodingAgents_Cli_Channel_Transport::maybe_claim( null, array( 'channel' => 'unknown' ) ) );
$prior = static fn() => null;
$assert( 'preserves prior handler', $prior === WpCodingAgents_Cli_Channel_Transport::maybe_claim( $prior, array( 'channel' => 'sync-true' ) ) );

$ok = WpCodingAgents_Cli_Channel_Transport::execute(
	array(
		'channel'   => 'sync-echo',
		'recipient' => 'user-1',
		'message'   => 'hi-there',
	)
);
$assert( 'sync success returns array', is_array( $ok ) && ! ( $ok instanceof WP_Error ) );
if ( is_array( $ok ) ) {
	$assert( 'sync success captures stdout', isset( $ok['metadata']['stdout'] ) && 'user-1:hi-there' === trim( (string) $ok['metadata']['stdout'] ) );
}

$assert( 'sync true succeeds', is_array( WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'sync-true', 'recipient' => 'r', 'message' => 'm' ) ) ) );
$fail = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'sync-false', 'recipient' => 'r', 'message' => 'm' ) );
$assert( 'nonzero exit returns WP_Error', $fail instanceof WP_Error && 'wp_coding_agents_cli_dispatch_nonzero_exit' === $fail->get_error_code() );
$timed = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'sync-sleep', 'recipient' => 'r', 'message' => 'm' ) );
$assert( 'timeout returns WP_Error', $timed instanceof WP_Error && 'wp_coding_agents_cli_dispatch_timeout' === $timed->get_error_code() );
$unknown = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'unknown', 'recipient' => 'r', 'message' => 'm' ) );
$assert( 'execute unknown returns WP_Error', $unknown instanceof WP_Error );

$detached = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'detached-true', 'recipient' => 'r', 'message' => 'm' ) );
$assert( 'detached returns array', is_array( $detached ) && true === ( $detached['sent'] ?? false ) );

// Regression: a detached child that exits non-zero must fail the dispatch
// instead of being reported as delivered (data-machine-code#643).
$detached_fail = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'detached-false', 'recipient' => 'r', 'message' => 'm' ) );
$assert( 'detached early exit returns WP_Error', $detached_fail instanceof WP_Error && 'wp_coding_agents_cli_dispatch_exit_nonzero' === $detached_fail->get_error_code() );

putenv( 'WP_CODING_AGENTS_PARENT_ENV=parent-ok' );
$inherited = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'inherit-env', 'recipient' => 'r', 'message' => 'm' ) );
$assert( 'empty channel env inherits parent env', is_array( $inherited ) && str_contains( (string) ( $inherited['metadata']['stdout'] ?? '' ), 'WP_CODING_AGENTS_PARENT_ENV=parent-ok' ) );

$configured = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'configured-env', 'recipient' => 'r', 'message' => 'm' ) );
$configured_stdout = is_array( $configured ) ? (string) ( $configured['metadata']['stdout'] ?? '' ) : '';
$assert( 'configured channel env keeps parent env', str_contains( $configured_stdout, 'WP_CODING_AGENTS_PARENT_ENV=parent-ok' ) );
$assert( 'configured channel env adds configured env', str_contains( $configured_stdout, 'WP_CODING_AGENTS_CONFIGURED_ENV=configured-ok' ) );

// #228 regression: when the caller's HOME is unwritable (PHP-FPM/WP-cron as
// www-data with HOME=/var/www) and the channel does not pin HOME, the
// transport must NOT pass the poisoned HOME through to the child — it drops
// it so the CLI falls back to a system default instead of dying with EACCES.
$poisoned_home = sys_get_temp_dir() . '/wpca-unwritable-home-' . getmypid();
$prev_home     = getenv( 'HOME' );
// A non-existent directory is, by definition, not a writable HOME.
putenv( 'HOME=' . $poisoned_home );
$guarded = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'guard-home', 'recipient' => 'r', 'message' => 'm' ) );
$guarded_stdout = is_array( $guarded ) ? (string) ( $guarded['metadata']['stdout'] ?? '' ) : '';
$assert( 'unwritable inherited HOME is not leaked', ! str_contains( $guarded_stdout, 'HOME=' . $poisoned_home ) );
$assert( 'guarded channel still inherits other parent env', str_contains( $guarded_stdout, 'WP_CODING_AGENTS_PARENT_ENV=parent-ok' ) );

// #228: a channel that pins a writable HOME keeps it even when the inherited
// HOME is poisoned — this is the kimaki installer's fix path.
$pinned = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'pinned-home', 'recipient' => 'r', 'message' => 'm' ) );
$pinned_stdout = is_array( $pinned ) ? (string) ( $pinned['metadata']['stdout'] ?? '' ) : '';
$assert( 'pinned writable HOME wins over poisoned inherited HOME', str_contains( $pinned_stdout, 'HOME=' . sys_get_temp_dir() ) );
// Restore HOME so any later code/tests see the original value.
if ( false === $prev_home ) {
	putenv( 'HOME' );
} else {
	putenv( 'HOME=' . $prev_home );
}

if ( ! empty( $failures ) ) {
	echo "\nFAIL: " . count( $failures ) . " assertion(s)\n";
	foreach ( $failures as $failure ) {
		echo "  - {$failure}\n";
	}
	exit( 1 );
}

echo "\nOK\n";
