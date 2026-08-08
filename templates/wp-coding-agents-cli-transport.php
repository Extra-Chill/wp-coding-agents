<?php
/**
 * Plugin Name: wp-coding-agents — CLI dispatch transport
 * Description: Generic local CLI transport for the agents/dispatch-message ability. Managed by wp-coding-agents setup/upgrade.
 *
 * @package wp-coding-agents
 */

defined( 'ABSPATH' ) || exit;

if ( ! class_exists( 'WpCodingAgents_Cli_Channel_Registry', false ) ) {
	/**
	 * Registry lookup for local CLI dispatch channels.
	 */
	class WpCodingAgents_Cli_Channel_Registry {
		/** New wp-coding-agents-owned registry key. */
		public const REGISTRY_KEY = 'wp_coding_agents_cli_channels';

		/** Legacy DMC registry key kept for migration compatibility. */
		public const LEGACY_REGISTRY_KEY = 'datamachine_code_cli_channels';

		/**
		 * Return the normalized registered channel map.
		 *
		 * @return array<string, array<string, mixed>>
		 */
		public static function get_channels(): array {
			$channels = array();

			foreach ( array( self::LEGACY_REGISTRY_KEY, self::REGISTRY_KEY ) as $key ) {
				$option_value = array();
				if ( function_exists( 'get_option' ) ) {
					$raw = get_option( $key, array() );
					if ( is_array( $raw ) ) {
						$option_value = $raw;
					}
				}

				$registered = $option_value;
				if ( function_exists( 'apply_filters' ) ) {
					$filtered = apply_filters( $key, $registered );
					if ( is_array( $filtered ) ) {
						$registered = $filtered;
					}
				}

				$channels = array_merge( $channels, $registered );
			}

			$valid = array();
			foreach ( $channels as $name => $config ) {
				if ( ! is_string( $name ) || '' === $name || ! is_array( $config ) ) {
					continue;
				}

				$normalized = self::normalize_entry( $config );
				if ( null !== $normalized ) {
					$valid[ $name ] = $normalized;
				}
			}

			return $valid;
		}

		/**
		 * Look up a single channel by name.
		 *
		 * @param string $channel Channel identifier.
		 * @return array<string, mixed>|null
		 */
		public static function lookup( string $channel ): ?array {
			if ( '' === $channel ) {
				return null;
			}

			$channels = self::get_channels();
			return $channels[ $channel ] ?? null;
		}

		/**
		 * Validate and normalize a channel config entry.
		 *
		 * @param array<string, mixed> $config Raw config entry.
		 * @return array<string, mixed>|null
		 */
		public static function normalize_entry( array $config ): ?array {
			$command = $config['command'] ?? null;
			if ( ! is_string( $command ) || '' === trim( $command ) ) {
				return null;
			}

			$args = $config['args'] ?? array();
			if ( ! is_array( $args ) ) {
				return null;
			}

			$normalized_args = array();
			foreach ( $args as $arg ) {
				if ( ! is_string( $arg ) ) {
					return null;
				}
				$normalized_args[] = $arg;
			}

			$timeout = $config['timeout'] ?? 30;
			if ( ! is_int( $timeout ) || $timeout < 1 ) {
				$timeout = 30;
			}

			$env = $config['env'] ?? array();
			if ( ! is_array( $env ) ) {
				$env = array();
			}

			$normalized_env = array();
			foreach ( $env as $env_key => $env_value ) {
				if ( is_string( $env_key ) && '' !== $env_key && is_scalar( $env_value ) ) {
					$normalized_env[ $env_key ] = (string) $env_value;
				}
			}

			$cwd = $config['cwd'] ?? null;
			if ( null !== $cwd && ( ! is_string( $cwd ) || '' === $cwd ) ) {
				$cwd = null;
			}

			return array(
				'command' => $command,
				'args'    => $normalized_args,
				'timeout' => $timeout,
				'env'     => $normalized_env,
				'cwd'     => $cwd,
			);
		}

		/**
		 * Substitute canonical dispatch-message tokens into argv templates.
		 *
		 * @param array<int, string>   $args  Template args.
		 * @param array<string, mixed> $input Dispatch input.
		 * @return array<int, string>
		 */
		public static function substitute_tokens( array $args, array $input ): array {
			$replacements = array(
				'{recipient}'       => self::stringify( $input['recipient'] ?? '' ),
				'{message}'         => self::stringify( $input['message'] ?? '' ),
				'{conversation_id}' => self::stringify( $input['conversation_id'] ?? '' ),
				'{channel}'         => self::stringify( $input['channel'] ?? '' ),
			);

			$result = array();
			foreach ( $args as $arg ) {
				$result[] = strtr( $arg, $replacements );
			}

			return $result;
		}

		/**
		 * Convert token input to a string.
		 *
		 * @param mixed $value Source value.
		 */
		private static function stringify( $value ): string {
			if ( null === $value ) {
				return '';
			}

			return is_scalar( $value ) ? (string) $value : '';
		}
	}
}

if ( ! class_exists( 'WpCodingAgents_Cli_Output_Redactor', false ) ) {
	/**
	 * Redact secrets from untrusted child-process diagnostics.
	 */
	class WpCodingAgents_Cli_Output_Redactor {
		private const REDACTED = '[redacted]';

		/**
		 * Redact generic credential patterns and known environment values.
		 *
		 * @param array<string, string> $configured_env Channel-configured environment.
		 */
		public static function redact( string $output, array $configured_env = array() ): string {
			$redacted = $output;
			foreach ( self::known_environment_values( $configured_env ) as $secret ) {
				$redacted = str_replace( $secret, self::REDACTED, $redacted );
			}

			$candidate = preg_replace(
				'/\b((?:(?:proxy-)?authorization|(?:set-)?cookie)\s*[:=]\s*)[^\r\n]+/i',
				'$1' . self::REDACTED,
				$redacted
			);
			$redacted  = is_string( $candidate ) ? $candidate : $redacted;

			$candidate = preg_replace( '/\bbearer\s+[A-Za-z0-9._~+\/=\-]{8,}/i', 'Bearer ' . self::REDACTED, $redacted );
			$redacted  = is_string( $candidate ) ? $candidate : $redacted;

			$candidate = preg_replace( '#\b(https?://)[^/\s:@]+:[^@/\s]+@#i', '$1' . self::REDACTED . ':' . self::REDACTED . '@', $redacted );
			$redacted  = is_string( $candidate ) ? $candidate : $redacted;

			$sensitive_key = '(?:(?:[a-z][a-z0-9]*[_-])*(?:api[_-]?key|access[_-]?token|refresh[_-]?token|auth(?:orization)?|client[_-]?secret|cookie|credentials?|nonce|password|passwd|private[_-]?key|secret|signature|token))';
			$candidate     = preg_replace( '/([?&]' . $sensitive_key . '=)[^&#\s]*/i', '$1' . self::REDACTED, $redacted );
			$redacted      = is_string( $candidate ) ? $candidate : $redacted;

			$assignment_pattern = '/(?P<prefix>(?:"|\')?\b' . $sensitive_key . '\b(?:"|\')?\s*[:=]\s*)(?P<value>"[^"\r\n]*"|\'[^\'\r\n]*\'|[^\s,;&#]+)/i';
			$assigned           = preg_replace_callback(
				$assignment_pattern,
				static function ( array $matches ): string {
					$value = $matches['value'];
					$quote = in_array( $value[0] ?? '', array( '"', "'" ), true ) ? $value[0] : '';
					return $matches['prefix'] . $quote . self::REDACTED . $quote;
				},
				$redacted
			);
			$redacted           = is_string( $assigned ) ? $assigned : $redacted;

			return $redacted;
		}

		/**
		 * Gather exact values that must not cross a diagnostic boundary.
		 *
		 * Every sufficiently distinctive configured value is treated as private;
		 * inherited values are included only when their key is sensitive.
		 *
		 * @param array<string, string> $configured_env Channel-configured environment.
		 * @return array<int, string>
		 */
		private static function known_environment_values( array $configured_env ): array {
			$values = array();
			foreach ( $configured_env as $value ) {
				if ( strlen( $value ) >= 8 ) {
					$values[] = $value;
				}
			}

			$inherited = getenv();
			if ( is_array( $inherited ) ) {
				foreach ( $inherited as $key => $value ) {
					if ( is_string( $key ) && is_string( $value ) && strlen( $value ) >= 8 && self::key_is_sensitive( $key ) ) {
						$values[] = $value;
					}
				}
			}

			$values = array_values( array_unique( $values ) );
			usort( $values, static fn( string $left, string $right ): int => strlen( $right ) <=> strlen( $left ) );
			return $values;
		}

		private static function key_is_sensitive( string $key ): bool {
			return 1 === preg_match( '/(?:api[_-]?key|auth|cookie|credential|nonce|password|passwd|private[_-]?key|secret|signature|token)/i', $key );
		}
	}
}

if ( ! class_exists( 'WpCodingAgents_Cli_Channel_Transport', false ) ) {
	/**
	 * Generic CLI transport for agents/dispatch-message.
	 */
	class WpCodingAgents_Cli_Channel_Transport {
		private const DEFAULT_TIMEOUT_SECONDS = 30;
		private const POLL_INTERVAL_MICROSECONDS = 20000;
		private const TERMINATION_GRACE_MICROSECONDS = 200000;

		/** Register the transport handler filter. */
		public static function register(): void {
			static $registered = false;
			if ( $registered || ! function_exists( 'add_filter' ) ) {
				return;
			}
			$registered = true;

			add_filter( 'wp_agent_dispatch_message_handler', array( self::class, 'maybe_claim' ), 10, 2 );
		}

		/**
		 * Claim dispatches for registered CLI channels.
		 *
		 * @param callable|null        $existing Existing handler.
		 * @param array<string, mixed> $input    Dispatch input.
		 * @return callable|null
		 */
		public static function maybe_claim( $existing, $input ) {
			if ( null !== $existing && is_callable( $existing ) ) {
				return $existing;
			}

			if ( ! is_array( $input ) || ! function_exists( 'proc_open' ) ) {
				return $existing;
			}

			$channel = isset( $input['channel'] ) && is_string( $input['channel'] ) ? $input['channel'] : '';
			if ( '' === $channel || null === WpCodingAgents_Cli_Channel_Registry::lookup( $channel ) ) {
				return $existing;
			}

			return array( self::class, 'execute' );
		}

		/**
		 * Execute the registered CLI dispatch.
		 *
		 * @param array<string, mixed> $input Dispatch input.
		 * @return array<string, mixed>|WP_Error
		 */
		public static function execute( array $input ) {
			$channel = isset( $input['channel'] ) && is_string( $input['channel'] ) ? $input['channel'] : '';
			if ( '' === $channel ) {
				return new WP_Error( 'wp_coding_agents_cli_dispatch_invalid_input', 'agents/dispatch-message input is missing a channel identifier.' );
			}

			$config = WpCodingAgents_Cli_Channel_Registry::lookup( $channel );
			if ( null === $config ) {
				return new WP_Error( 'wp_coding_agents_cli_dispatch_unknown_channel', sprintf( 'No CLI channel registered for "%s".', $channel ) );
			}

			$recipient    = isset( $input['recipient'] ) && is_scalar( $input['recipient'] ) ? (string) $input['recipient'] : '';
			$command_args = WpCodingAgents_Cli_Channel_Registry::substitute_tokens( $config['args'], $input );
			array_unshift( $command_args, $config['command'] );

			$timeout = isset( $config['timeout'] ) && is_int( $config['timeout'] ) ? $config['timeout'] : self::DEFAULT_TIMEOUT_SECONDS;
			$cwd     = isset( $config['cwd'] ) && is_string( $config['cwd'] ) && '' !== $config['cwd'] ? $config['cwd'] : null;
			$configured_env = isset( $config['env'] ) && is_array( $config['env'] ) ? $config['env'] : array();
			$env            = self::build_env_map( $configured_env );

			return self::dispatch_sync( $channel, $recipient, $command_args, $cwd, $env, $timeout, $configured_env );
		}

		/**
		 * @param array<int, string>         $argv Command argv.
		 * @param array<string, string>|null $env  Environment map.
		 * @return array<string, mixed>|WP_Error
		 */
		private static function dispatch_sync( string $channel, string $recipient, array $argv, ?string $cwd, ?array $env, int $timeout, array $configured_env ) {
			$descriptors = array(
				0 => array( 'pipe', 'r' ),
				1 => array( 'pipe', 'w' ),
				2 => array( 'pipe', 'w' ),
			);

			$pipes      = array();
			$started_at = microtime( true );
			$process    = self::open_process( $argv, $descriptors, $cwd, $env, $pipes );
			if ( $process instanceof WP_Error ) {
				return $process;
			}

			if ( isset( $pipes[0] ) && is_resource( $pipes[0] ) ) {
				fclose( $pipes[0] );
			}
			if ( isset( $pipes[1] ) && is_resource( $pipes[1] ) ) {
				stream_set_blocking( $pipes[1], false );
			}
			if ( isset( $pipes[2] ) && is_resource( $pipes[2] ) ) {
				stream_set_blocking( $pipes[2], false );
			}

			$stdout       = '';
			$stderr       = '';
			$timed_out    = false;
			$exit_code    = null;
			$deadline     = $started_at + $timeout;
			$pid          = null;
			$first_status = proc_get_status( $process );
			if ( is_array( $first_status ) && isset( $first_status['pid'] ) ) {
				$pid = (int) $first_status['pid'];
			}
			$status = $first_status;

			while ( true ) {
				self::drain_output( $pipes, $stdout, $stderr );

				if ( ! is_array( $status ) || false === $status['running'] ) {
					if ( is_array( $status ) && isset( $status['exitcode'] ) && -1 !== (int) $status['exitcode'] ) {
						$exit_code = (int) $status['exitcode'];
					}
					break;
				}
				if ( microtime( true ) >= $deadline ) {
					$timed_out = true;
					self::terminate_process_tree( $process, $pid, $pipes, $stdout, $stderr );
					break;
				}

				usleep( self::POLL_INTERVAL_MICROSECONDS );
				$status = proc_get_status( $process );
			}

			self::drain_output( $pipes, $stdout, $stderr );
			self::close_output_pipes( $pipes );

			$close_code = proc_close( $process );
			if ( null === $exit_code && is_int( $close_code ) && -1 !== $close_code ) {
				$exit_code = $close_code;
			}
			$duration_ms = (int) round( ( microtime( true ) - $started_at ) * 1000 );
			$stdout      = self::sanitize_output( $stdout, $configured_env );
			$stderr      = self::sanitize_output( $stderr, $configured_env );

			if ( $timed_out ) {
				return new WP_Error( 'wp_coding_agents_cli_dispatch_timeout', sprintf( 'CLI channel "%s" exceeded the %d second timeout.', $channel, $timeout ), array( 'channel' => $channel, 'recipient' => $recipient, 'stdout' => $stdout, 'stderr' => $stderr, 'duration_ms' => $duration_ms ) );
			}

			if ( null === $exit_code || 0 !== $exit_code ) {
				$exit_description = null === $exit_code ? 'without a readable exit code' : sprintf( 'with code %d', $exit_code );
				return new WP_Error( 'wp_coding_agents_cli_dispatch_nonzero_exit', sprintf( 'CLI channel "%s" exited %s.', $channel, $exit_description ), array( 'channel' => $channel, 'recipient' => $recipient, 'exit_code' => $exit_code, 'stdout' => $stdout, 'stderr' => $stderr, 'duration_ms' => $duration_ms ) );
			}

			return array(
				'sent'       => true,
				'channel'    => $channel,
				'recipient'  => $recipient,
				'message_id' => null,
				'metadata'   => array(
					'mode'        => 'synchronous-session-isolated',
					'pid'         => $pid,
					'exit_code'   => $exit_code,
					'duration_ms' => $duration_ms,
				),
			);
		}

		/**
		 * @param array<int, string>         $argv        Command argv.
		 * @param array<int, mixed>          $descriptors Descriptor spec.
		 * @param array<string, string>|null $env         Environment map.
		 * @param array<int, resource>       $pipes       Output pipes.
		 * @return resource|WP_Error
		 */
		private static function open_process( array $argv, array $descriptors, ?string $cwd, ?array $env, array &$pipes = array() ) {
			if ( ! function_exists( 'proc_open' ) ) {
				return new WP_Error( 'wp_coding_agents_cli_dispatch_no_proc_open', 'proc_open is not available on this host.' );
			}
			if ( ! function_exists( 'posix_kill' ) ) {
				return new WP_Error( 'wp_coding_agents_cli_dispatch_no_posix_kill', 'The POSIX process extension is required for bounded CLI process-tree cleanup.' );
			}

			$session_launcher = self::find_session_launcher();
			if ( null === $session_launcher ) {
				return new WP_Error( 'wp_coding_agents_cli_dispatch_no_session_launcher', 'A POSIX setsid executable is required for bounded CLI process-tree cleanup.' );
			}

			array_unshift( $argv, $session_launcher, '--' );
			$process = @proc_open( $argv, $descriptors, $pipes, $cwd, $env );
			if ( ! is_resource( $process ) ) {
				return new WP_Error( 'wp_coding_agents_cli_dispatch_spawn_failed', 'Failed to spawn CLI process.' );
			}

			return $process;
		}

		/** Locate the POSIX session launcher without invoking a shell. */
		private static function find_session_launcher(): ?string {
			$candidates = array( '/usr/bin/setsid', '/bin/setsid' );
			$path       = getenv( 'PATH' );
			if ( is_string( $path ) ) {
				foreach ( explode( PATH_SEPARATOR, $path ) as $directory ) {
					if ( '' !== $directory ) {
						$candidates[] = rtrim( $directory, DIRECTORY_SEPARATOR ) . DIRECTORY_SEPARATOR . 'setsid';
					}
				}
			}

			foreach ( array_unique( $candidates ) as $candidate ) {
				if ( is_file( $candidate ) && is_executable( $candidate ) ) {
					return $candidate;
				}
			}

			return null;
		}

		/**
		 * Drain currently available child output without blocking.
		 *
		 * @param array<int, resource> $pipes  Process pipes.
		 * @param string               $stdout Collected standard output.
		 * @param string               $stderr Collected standard error.
		 */
		private static function drain_output( array $pipes, string &$stdout, string &$stderr ): void {
			foreach ( array( 1, 2 ) as $fd ) {
				if ( ! isset( $pipes[ $fd ] ) || ! is_resource( $pipes[ $fd ] ) ) {
					continue;
				}
				$chunk = stream_get_contents( $pipes[ $fd ] );
				if ( is_string( $chunk ) && '' !== $chunk ) {
					if ( 1 === $fd ) {
						$stdout .= $chunk;
					} else {
						$stderr .= $chunk;
					}
				}
			}
		}

		/** @param array<int, resource> $pipes Process pipes. */
		private static function close_output_pipes( array $pipes ): void {
			foreach ( array( 1, 2 ) as $fd ) {
				if ( isset( $pipes[ $fd ] ) && is_resource( $pipes[ $fd ] ) ) {
					fclose( $pipes[ $fd ] );
				}
			}
		}

		/**
		 * Terminate the isolated process group, escalating after a short grace.
		 *
		 * @param resource             $process Child process resource.
		 * @param array<int, resource> $pipes   Process pipes.
		 */
		private static function terminate_process_tree( $process, ?int $pid, array $pipes, string &$stdout, string &$stderr ): void {
			self::signal_process_tree( $process, $pid, 15 );
			$grace_deadline = microtime( true ) + ( self::TERMINATION_GRACE_MICROSECONDS / 1000000 );
			while ( microtime( true ) < $grace_deadline ) {
				self::drain_output( $pipes, $stdout, $stderr );
				if ( ! self::process_tree_is_running( $process, $pid ) ) {
					return;
				}
				usleep( self::POLL_INTERVAL_MICROSECONDS );
			}

			self::signal_process_tree( $process, $pid, 9 );
			$kill_deadline = microtime( true ) + ( self::TERMINATION_GRACE_MICROSECONDS / 1000000 );
			while ( microtime( true ) < $kill_deadline && self::process_tree_is_running( $process, $pid ) ) {
				self::drain_output( $pipes, $stdout, $stderr );
				usleep( self::POLL_INTERVAL_MICROSECONDS );
			}
		}

		/** @param resource $process Child process resource. */
		private static function signal_process_tree( $process, ?int $pid, int $signal ): void {
			if ( null !== $pid && $pid > 0 && @posix_kill( -$pid, $signal ) ) {
				return;
			}

			proc_terminate( $process, $signal );
		}

		/** @param resource $process Child process resource. */
		private static function process_tree_is_running( $process, ?int $pid ): bool {
			if ( null !== $pid && $pid > 0 ) {
				return @posix_kill( -$pid, 0 );
			}

			$status = proc_get_status( $process );
			return is_array( $status ) && true === ( $status['running'] ?? false );
		}

		/**
		 * Build the child process environment for a dispatched CLI.
		 *
		 * The base is the inherited parent env (with PATH special-cased so a
		 * stripped-down FPM/cron env still resolves binaries), then the
		 * channel-configured `env` map is overlaid on top — that overlay is
		 * where a channel pins vendor-specific values such as a writable HOME
		 * / data-dir (see the CLI-channel registry installer).
		 *
		 * Generic HOME guard (defense-in-depth, layer-pure — no vendor names,
		 * no hardcoded paths): this transport is shelled from PHP-FPM / WP-cron,
		 * which often run as a web user whose HOME points at a non-writable,
		 * root-owned directory (e.g. /var/www). Many CLIs create a per-user
		 * data dir under $HOME at startup and die with EACCES on such a HOME.
		 * If the resolved env does not carry an explicit, writable HOME (either
		 * inherited or channel-configured), we UNSET HOME entirely rather than
		 * pass a poisoned value through — proc_open then leaves HOME to the
		 * system/account default instead of a guaranteed-unwritable path. The
		 * correct positive HOME value, when one is required, comes from the
		 * channel config (installer-written), keeping vendor specifics out of
		 * this generic layer.
		 *
		 * @param array<string, string> $configured Configured env map.
		 * @return array<string, string>|null
		 */
		private static function build_env_map( array $configured ): ?array {
			$home_configured = array_key_exists( 'HOME', $configured );

			// Fast path: no channel config AND the inherited HOME is sane —
			// nothing to normalize, inherit the full parent env as before.
			if ( empty( $configured ) && self::inherited_home_is_writable() ) {
				return null;
			}

			$parent_env = getenv();
			$env        = is_array( $parent_env ) ? array_filter( $parent_env, 'is_string' ) : array();

			if ( ! isset( $env['PATH'] ) ) {
				$parent_path = getenv( 'PATH' );
				if ( is_string( $parent_path ) && '' !== $parent_path ) {
					$env['PATH'] = $parent_path;
				}
			}

			foreach ( $configured as $key => $value ) {
				$env[ $key ] = $value;
			}

			// If HOME wasn't pinned by the channel and the effective HOME is
			// empty or unwritable, drop it rather than hand the child a
			// poisoned path. The concrete writable HOME, when needed, is the
			// channel config's job — not this generic transport's.
			if ( ! $home_configured && ! self::home_value_is_writable( $env['HOME'] ?? null ) ) {
				unset( $env['HOME'] );
			}

			return $env;
		}

		/**
		 * Whether the inherited (process) HOME is set and writable by us.
		 *
		 * @return bool
		 */
		private static function inherited_home_is_writable(): bool {
			$home = getenv( 'HOME' );
			return self::home_value_is_writable( is_string( $home ) ? $home : null );
		}

		/**
		 * Whether a HOME value is a non-empty, existing, writable directory.
		 *
		 * @param string|null $home Candidate HOME path.
		 * @return bool
		 */
		private static function home_value_is_writable( ?string $home ): bool {
			if ( null === $home || '' === $home ) {
				return false;
			}
			return is_dir( $home ) && is_writable( $home );
		}

		private static function truncate_output( string $output ): string {
			$limit = 8192;
			if ( strlen( $output ) <= $limit ) {
				return $output;
			}

			return substr( $output, 0, $limit ) . "\n[...truncated]";
		}

		/** @param array<string, string> $configured_env Channel-configured environment. */
		private static function sanitize_output( string $output, array $configured_env ): string {
			return self::truncate_output( WpCodingAgents_Cli_Output_Redactor::redact( $output, $configured_env ) );
		}
	}
}

WpCodingAgents_Cli_Channel_Transport::register();
