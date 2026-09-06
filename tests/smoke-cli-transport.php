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

if ( ! function_exists( 'update_option' ) ) {
	function update_option( string $key, mixed $value ): bool {
		global $wp_coding_agents_test_options;
		$wp_coding_agents_test_options[ $key ] = $value;
		return true;
	}
}

if ( ! function_exists( 'delete_option' ) ) {
	function delete_option( string $key ): bool {
		global $wp_coding_agents_test_options;
		unset( $wp_coding_agents_test_options[ $key ] );
		return true;
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
$true_bin  = $find_stub( array( '/bin/true', '/usr/bin/true' ) );
$false_bin = $find_stub( array( '/bin/false', '/usr/bin/false' ) );
$sleep_bin = $find_stub( array( '/bin/sleep', '/usr/bin/sleep' ) );
$php_bin   = is_executable( PHP_BINARY ) ? PHP_BINARY : null;
foreach ( array( 'echo' => $echo_bin, 'true' => $true_bin, 'false' => $false_bin, 'sleep' => $sleep_bin, 'php' => $php_bin ) as $name => $path ) {
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
$assert( 'legacy detach key is not part of normalized contract', is_array( $normalized ) && ! array_key_exists( 'detach', $normalized ) );
$assert( 'non-positive timeout resets to bounded default', 30 === WpCodingAgents_Cli_Channel_Registry::normalize_entry( array( 'command' => $echo_bin, 'timeout' => 0 ) )['timeout'] );
$assert( 'missing command is rejected', null === WpCodingAgents_Cli_Channel_Registry::normalize_entry( array( 'args' => array() ) ) );
$assert( 'non-string arg is rejected', null === WpCodingAgents_Cli_Channel_Registry::normalize_entry( array( 'command' => $echo_bin, 'args' => array( 123 ) ) ) );

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
$wp_coding_agents_test_options['datamachine_code_cli_channels'] = array(
	'legacy-option' => array(
		'command' => $echo_bin,
		'args'    => array( 'legacy-option' ),
	),
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
$assert( 'legacy option channel is migrated', isset( $channels['legacy-option'] ) );
$assert( 'retired option is removed after migration', ! isset( $wp_coding_agents_test_options['datamachine_code_cli_channels'] ) );
$assert( 'migrated channel is stored in the canonical option', isset( $wp_coding_agents_test_options['wp_coding_agents_cli_channels']['legacy-option'] ) );
$assert( 'new option channel is present', isset( $channels['new-option'] ) );
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

$redaction_fixture = implode(
	"\n",
	array(
		'Authorization: Bearer bearer-secret-123456',
		'Proxy-Authorization: Basic dXNlcjpwYXNzd29yZA==',
		'Cookie: session=cookie-secret',
		'OPENAI_API_KEY=assignment-secret',
		'"refresh_token": "json-secret"',
		'Authorization=Bearer assignment-bearer-secret',
		'https://user:password@example.com/callback?access_token=query-secret&state=public',
		'safe multiline detail',
	)
);
$redacted_fixture = WpCodingAgents_Cli_Output_Redactor::redact( $redaction_fixture );
$assert( 'bearer authorization is redacted', ! str_contains( $redacted_fixture, 'bearer-secret-123456' ) && ! str_contains( $redacted_fixture, 'assignment-bearer-secret' ) );
$assert( 'basic authorization is redacted', ! str_contains( $redacted_fixture, 'dXNlcjpwYXNzd29yZA==' ) );
$assert( 'cookie header is redacted', ! str_contains( $redacted_fixture, 'cookie-secret' ) );
$assert( 'secret assignments are redacted', ! str_contains( $redacted_fixture, 'assignment-secret' ) && ! str_contains( $redacted_fixture, 'json-secret' ) );
$assert( 'URL credentials are redacted', ! str_contains( $redacted_fixture, 'user:password' ) );
$assert( 'URL query secrets are redacted', ! str_contains( $redacted_fixture, 'query-secret' ) );
$assert( 'multiline safe detail is preserved', str_contains( $redacted_fixture, "\nsafe multiline detail" ) );

$known_env_secret = '/private/configured/path/known-secret';
$known_redacted   = WpCodingAgents_Cli_Output_Redactor::redact( 'diagnostic: ' . $known_env_secret, array( 'OPAQUE_VALUE' => $known_env_secret ) );
$assert( 'configured environment values are redacted', ! str_contains( $known_redacted, $known_env_secret ) && str_contains( $known_redacted, '[redacted]' ) );

$safe_fixture  = 'token count: 5; secret sauce; Basic skills; https://example.com/?page=1&state=public';
$safe_redacted = WpCodingAgents_Cli_Output_Redactor::redact( $safe_fixture );
$assert( 'non-secret prose resists false positives', $safe_fixture === $safe_redacted );

$tree_pid_file = tempnam( sys_get_temp_dir(), 'wpca-tree-pid-' );
if ( false !== $tree_pid_file ) {
	@unlink( $tree_pid_file );
}
$tree_parent_code = false !== $tree_pid_file
	? '$descriptors = array( 0 => array( "file", "/dev/null", "r" ), 1 => array( "file", "/dev/null", "w" ), 2 => array( "file", "/dev/null", "w" ) );'
		. '$child = proc_open( array( PHP_BINARY, "-r", "while ( true ) { usleep( 100000 ); }" ), $descriptors, $pipes );'
		. '$status = proc_get_status( $child ); file_put_contents( ' . var_export( $tree_pid_file, true ) . ', (string) $status["pid"] );'
		. 'while ( true ) { usleep( 100000 ); }'
	: '';

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
		'startup-fail'  => array(
			'command' => '/definitely/missing/wpca-cli',
			'args'    => array(),
			'timeout' => 5,
		),
		'sync-sleep'    => array(
			'command' => $sleep_bin,
			'args'    => array( '5' ),
			'detach'  => false,
			'timeout' => 1,
		),
		'timeout-secret' => array(
			'command' => $php_bin,
			'args'    => array( '-r', 'fwrite(STDERR, "refresh_token=timeout-secret\\n"); sleep(5);' ),
			'detach'  => false,
			'timeout' => 1,
		),
		'long-running-success' => array(
			'command' => $php_bin,
			'args'    => array( '-r', 'usleep( 1100000 ); fwrite( STDOUT, "completed" );' ),
			'timeout' => 3,
		),
		'tree-timeout' => array(
			'command' => $php_bin,
			'args'    => array( '-r', $tree_parent_code ),
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
		'detached-secret' => array(
			'command' => $php_bin,
			'args'    => array( '-r', 'fwrite(STDERR, "Authorization: Bearer detached-secret-token\\n"); exit(7);' ),
			'detach'  => true,
		),
		'diagnostics-fail' => array(
			'command' => $php_bin,
			'args'    => array( '-r', 'fwrite(STDOUT, "token=stdout-secret\\nsafe stdout\\n"); fwrite(STDERR, "Authorization: Basic stderr-secret\\nsafe stderr\\n"); exit(9);' ),
			'detach'  => false,
			'timeout' => 5,
		),
		'configured-secret-fail' => array(
			'command' => $php_bin,
			'args'    => array( '-r', 'fwrite(STDERR, "opaque=" . getenv("OPAQUE_VALUE")); exit(9);' ),
			'detach'  => false,
			'timeout' => 5,
			'env'     => array(
				'OPAQUE_VALUE' => $known_env_secret,
			),
		),
		'truncation-order-fail' => array(
			'command' => $php_bin,
			'args'    => array( '-r', 'fwrite(STDERR, str_repeat("x", 8170) . " token=" . str_repeat("z", 100)); exit(9);' ),
			'detach'  => false,
			'timeout' => 5,
		),
		'inherit-env'   => array(
			'command' => $php_bin,
			'args'    => array( '-r', 'exit("parent-ok" === getenv("WP_CODING_AGENTS_PARENT_ENV") ? 0 : 11);' ),
			'detach'  => false,
			'timeout' => 5,
		),
		'configured-env' => array(
			'command' => $php_bin,
			'args'    => array( '-r', 'exit("parent-ok" === getenv("WP_CODING_AGENTS_PARENT_ENV") && "configured-ok" === getenv("WP_CODING_AGENTS_CONFIGURED_ENV") ? 0 : 11);' ),
			'detach'  => false,
			'timeout' => 5,
			'env'     => array(
				'WP_CODING_AGENTS_CONFIGURED_ENV' => 'configured-ok',
			),
		),
		// #228: a channel with no configured HOME must not have a poisoned
		// (unwritable) inherited HOME leak through to the child.
		'guard-home'    => array(
			'command' => $php_bin,
			'args'    => array( '-r', 'exit(false === getenv("HOME") && "parent-ok" === getenv("WP_CODING_AGENTS_PARENT_ENV") ? 0 : 11);' ),
			'detach'  => false,
			'timeout' => 5,
		),
		// #228: a channel that pins a writable HOME keeps it verbatim.
		'pinned-home'   => array(
			'command' => $php_bin,
			'args'    => array( '-r', 'exit(getenv("HOME") === sys_get_temp_dir() ? 0 : 11);' ),
			'detach'  => false,
			'timeout' => 5,
			'env'     => array(
				'HOME' => sys_get_temp_dir(),
			),
		),
	),
);

$assert( 'undeclared host declines process-backed channel', null === WpCodingAgents_Cli_Channel_Transport::maybe_claim( null, array( 'channel' => 'sync-true' ) ) );
add_filter( 'wp_coding_agents_host_can_execute_processes', static fn( bool $available ): bool => false );
$assert( 'unavailable host declines process-backed channel', null === WpCodingAgents_Cli_Channel_Transport::maybe_claim( null, array( 'channel' => 'sync-true' ) ) );
$wp_coding_agents_test_filters['wp_coding_agents_host_can_execute_processes'] = array();
require_once __DIR__ . '/../carried-plugins/wp-coding-agents-integration/wp-coding-agents-integration.php';

$installed_host_can_execute = \WpCodingAgents\Integration\HostCapabilities::can_execute_processes();
$claim_known = WpCodingAgents_Cli_Channel_Transport::maybe_claim( null, array( 'channel' => 'sync-true' ) );
$assert( 'installed host claim reflects executable capability', $installed_host_can_execute === is_callable( $claim_known ) );
$assert( 'installed provider rechecks an explicit capable declaration', $installed_host_can_execute === apply_filters( 'wp_coding_agents_host_can_execute_processes', true ) );
add_filter( 'wp_coding_agents_host_can_execute_processes', static fn( bool $available ): bool => false, 20 );
$assert( 'later denial overrides an explicit capable declaration', false === apply_filters( 'wp_coding_agents_host_can_execute_processes', true ) );
$assert( 'later integration-owned denial overrides installed provider', null === WpCodingAgents_Cli_Channel_Transport::maybe_claim( null, array( 'channel' => 'sync-true' ) ) );
$wp_coding_agents_test_filters['wp_coding_agents_host_can_execute_processes'][20] = array();
$portable_argv = Closure::bind(
	static function (): array {
		return self::session_launcher_argv( '/fixture/setsid', array( '/bin/true', '--child-option' ) );
	},
	null,
	WpCodingAgents_Cli_Channel_Transport::class
)();
$assert( 'portable setsid invocation keeps the child command first', array( '/fixture/setsid', '/bin/true', '--child-option' ) === $portable_argv );
if ( ! $installed_host_can_execute ) {
	echo "  [SKIP] installed host cannot meet the session-safe process contract\n";
	exit( 0 );
}

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
	$assert( 'sync success omits child output', ! isset( $ok['metadata']['stdout'] ) && ! isset( $ok['metadata']['stderr'] ) );
}

$assert( 'sync true succeeds', is_array( WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'sync-true', 'recipient' => 'r', 'message' => 'm' ) ) ) );
$assert( 'successful completion is idempotent', is_array( WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'sync-true', 'recipient' => 'r', 'message' => 'm' ) ) ) );
$fail = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'sync-false', 'recipient' => 'r', 'message' => 'm' ) );
$assert( 'nonzero exit returns WP_Error', $fail instanceof WP_Error && 'wp_coding_agents_cli_dispatch_nonzero_exit' === $fail->get_error_code() );
$startup_fail = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'startup-fail', 'recipient' => 'r', 'message' => 'm' ) );
$startup_data = $startup_fail instanceof WP_Error ? (array) $startup_fail->get_error_data() : array();
$assert( 'startup failure returns WP_Error', $startup_fail instanceof WP_Error && 'wp_coding_agents_cli_dispatch_nonzero_exit' === $startup_fail->get_error_code() );
$assert( 'startup failure preserves stderr diagnostics', isset( $startup_data['stderr'] ) && '' !== $startup_data['stderr'] );
$long_running = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'long-running-success', 'recipient' => 'r', 'message' => 'm' ) );
$assert( 'long-running child succeeds within timeout', is_array( $long_running ) && 'synchronous-session-isolated' === ( $long_running['metadata']['mode'] ?? null ) );
$timeout_started = microtime( true );
$timed = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'sync-sleep', 'recipient' => 'r', 'message' => 'm' ) );
$assert( 'timeout returns WP_Error', $timed instanceof WP_Error && 'wp_coding_agents_cli_dispatch_timeout' === $timed->get_error_code() );
$assert( 'timeout return is bounded', microtime( true ) - $timeout_started < 3 );
$timed_secret = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'timeout-secret', 'recipient' => 'r', 'message' => 'm' ) );
$timed_data   = $timed_secret instanceof WP_Error ? (array) $timed_secret->get_error_data() : array();
$assert( 'timeout structured stderr is redacted', isset( $timed_data['stderr'] ) && ! str_contains( (string) $timed_data['stderr'], 'timeout-secret' ) && str_contains( (string) $timed_data['stderr'], '[redacted]' ) );
$unknown = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'unknown', 'recipient' => 'r', 'message' => 'm' ) );
$assert( 'execute unknown returns WP_Error', $unknown instanceof WP_Error );

$detached = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'detached-true', 'recipient' => 'r', 'message' => 'm' ) );
$assert( 'legacy detach config runs synchronously', is_array( $detached ) && 'synchronous-session-isolated' === ( $detached['metadata']['mode'] ?? null ) );

// Regression: a legacy detach key must not bypass exit acknowledgement.
$detached_fail = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'detached-false', 'recipient' => 'r', 'message' => 'm' ) );
$assert( 'legacy detach early exit returns WP_Error', $detached_fail instanceof WP_Error && 'wp_coding_agents_cli_dispatch_nonzero_exit' === $detached_fail->get_error_code() );

$detached_secret = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'detached-secret', 'recipient' => 'r', 'message' => 'm' ) );
$detached_data   = $detached_secret instanceof WP_Error ? (array) $detached_secret->get_error_data() : array();
$assert( 'legacy detach error message omits child output', $detached_secret instanceof WP_Error && ! str_contains( $detached_secret->get_error_message(), 'detached-secret-token' ) );
$assert( 'legacy detach structured stderr is redacted', isset( $detached_data['stderr'] ) && ! str_contains( (string) $detached_data['stderr'], 'detached-secret-token' ) && str_contains( (string) $detached_data['stderr'], '[redacted]' ) );

if ( false === $tree_pid_file || ! function_exists( 'posix_kill' ) ) {
	$assert( 'process-tree cleanup prerequisites available', false );
} else {
	$tree_timeout = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'tree-timeout', 'recipient' => 'r', 'message' => 'm' ) );
	$assert( 'process-tree fixture times out', $tree_timeout instanceof WP_Error && 'wp_coding_agents_cli_dispatch_timeout' === $tree_timeout->get_error_code() );
	$tree_pid = is_file( $tree_pid_file ) ? (int) file_get_contents( $tree_pid_file ) : 0;
	$tree_running = $tree_pid > 0;
	for ( $attempt = 0; $tree_running && $attempt < 50; $attempt++ ) {
		$stat = @file_get_contents( '/proc/' . $tree_pid . '/stat' );
		$fields = is_string( $stat ) ? explode( ' ', $stat ) : array();
		$tree_running = @posix_kill( $tree_pid, 0 ) && 'Z' !== ( $fields[2] ?? null );
		if ( $tree_running ) {
			usleep( 20000 );
		}
	}
	$assert( 'timeout terminates descendant process', $tree_pid > 0 && ! $tree_running );
	@unlink( $tree_pid_file );
}

$diagnostic_fail = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'diagnostics-fail', 'recipient' => 'r', 'message' => 'm' ) );
$diagnostic_data = $diagnostic_fail instanceof WP_Error ? (array) $diagnostic_fail->get_error_data() : array();
$assert( 'sync structured stdout is redacted', isset( $diagnostic_data['stdout'] ) && ! str_contains( (string) $diagnostic_data['stdout'], 'stdout-secret' ) && str_contains( (string) $diagnostic_data['stdout'], 'safe stdout' ) );
$assert( 'sync structured stderr is redacted', isset( $diagnostic_data['stderr'] ) && ! str_contains( (string) $diagnostic_data['stderr'], 'stderr-secret' ) && str_contains( (string) $diagnostic_data['stderr'], 'safe stderr' ) );

$configured_fail = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'configured-secret-fail', 'recipient' => 'r', 'message' => 'm' ) );
$configured_data = $configured_fail instanceof WP_Error ? (array) $configured_fail->get_error_data() : array();
$assert( 'configured value is redacted at error boundary', isset( $configured_data['stderr'] ) && ! str_contains( (string) $configured_data['stderr'], $known_env_secret ) );

$truncation_fail = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'truncation-order-fail', 'recipient' => 'r', 'message' => 'm' ) );
$truncation_data = $truncation_fail instanceof WP_Error ? (array) $truncation_fail->get_error_data() : array();
$assert( 'redaction occurs before truncation', isset( $truncation_data['stderr'] ) && ! str_contains( (string) $truncation_data['stderr'], str_repeat( 'z', 20 ) ) && ! str_contains( (string) $truncation_data['stderr'], '[...truncated]' ) );

putenv( 'WP_CODING_AGENTS_PARENT_ENV=parent-ok' );
$inherited = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'inherit-env', 'recipient' => 'r', 'message' => 'm' ) );
$assert( 'empty channel env inherits parent env', is_array( $inherited ) );

$configured = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'configured-env', 'recipient' => 'r', 'message' => 'm' ) );
$assert( 'configured channel env keeps parent and adds configured env', is_array( $configured ) );

// #228 regression: when the caller's HOME is unwritable (PHP-FPM/WP-cron as
// www-data with HOME=/var/www) and the channel does not pin HOME, the
// transport must NOT pass the poisoned HOME through to the child — it drops
// it so the CLI falls back to a system default instead of dying with EACCES.
$poisoned_home = sys_get_temp_dir() . '/wpca-unwritable-home-' . getmypid();
$prev_home     = getenv( 'HOME' );
// A non-existent directory is, by definition, not a writable HOME.
putenv( 'HOME=' . $poisoned_home );
$guarded = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'guard-home', 'recipient' => 'r', 'message' => 'm' ) );
$assert( 'unwritable HOME is dropped while other parent env is inherited', is_array( $guarded ) );

// #228: a channel that pins a writable HOME keeps it even when the inherited
// HOME is poisoned — this is the kimaki installer's fix path.
$pinned = WpCodingAgents_Cli_Channel_Transport::execute( array( 'channel' => 'pinned-home', 'recipient' => 'r', 'message' => 'm' ) );
$assert( 'pinned writable HOME wins over poisoned inherited HOME', is_array( $pinned ) );
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
