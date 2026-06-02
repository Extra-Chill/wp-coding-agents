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

			$detach = $config['detach'] ?? true;
			if ( ! is_bool( $detach ) ) {
				$detach = (bool) $detach;
			}

			$timeout = $config['timeout'] ?? 30;
			if ( ! is_int( $timeout ) || $timeout < 0 ) {
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
				'detach'  => $detach,
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

if ( ! class_exists( 'WpCodingAgents_Cli_Channel_Transport', false ) ) {
	/**
	 * Generic CLI transport for agents/dispatch-message.
	 */
	class WpCodingAgents_Cli_Channel_Transport {
		private const DEFAULT_TIMEOUT_SECONDS = 30;

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

			$detach = (bool) ( $config['detach'] ?? true );
			$timeout = isset( $config['timeout'] ) && is_int( $config['timeout'] ) ? $config['timeout'] : self::DEFAULT_TIMEOUT_SECONDS;
			$cwd     = isset( $config['cwd'] ) && is_string( $config['cwd'] ) && '' !== $config['cwd'] ? $config['cwd'] : null;
			$env     = self::build_env_map( isset( $config['env'] ) && is_array( $config['env'] ) ? $config['env'] : array() );

			if ( $detach ) {
				return self::dispatch_detached( $channel, $recipient, $command_args, $cwd, $env );
			}

			return self::dispatch_sync( $channel, $recipient, $command_args, $cwd, $env, $timeout );
		}

		/**
		 * @param array<int, string>         $argv Command argv.
		 * @param array<string, string>|null $env  Environment map.
		 * @return array<string, mixed>|WP_Error
		 */
		private static function dispatch_detached( string $channel, string $recipient, array $argv, ?string $cwd, ?array $env ) {
			$descriptors = array(
				0 => array( 'file', '/dev/null', 'r' ),
				1 => array( 'file', '/dev/null', 'w' ),
				2 => array( 'file', '/dev/null', 'w' ),
			);

			$started_at = microtime( true );
			$process    = self::open_process( $argv, $descriptors, $cwd, $env, true );
			if ( $process instanceof WP_Error ) {
				return $process;
			}

			$pid    = null;
			$status = proc_get_status( $process );
			if ( is_array( $status ) && isset( $status['pid'] ) ) {
				$pid = (int) $status['pid'];
			}

			proc_close( $process );

			return array(
				'sent'       => true,
				'channel'    => $channel,
				'recipient'  => $recipient,
				'message_id' => null !== $pid ? (string) $pid : null,
				'metadata'   => array(
					'mode'        => 'detached',
					'pid'         => $pid,
					'duration_ms' => (int) round( ( microtime( true ) - $started_at ) * 1000 ),
				),
			);
		}

		/**
		 * @param array<int, string>         $argv Command argv.
		 * @param array<string, string>|null $env  Environment map.
		 * @return array<string, mixed>|WP_Error
		 */
		private static function dispatch_sync( string $channel, string $recipient, array $argv, ?string $cwd, ?array $env, int $timeout ) {
			$descriptors = array(
				0 => array( 'pipe', 'r' ),
				1 => array( 'pipe', 'w' ),
				2 => array( 'pipe', 'w' ),
			);

			$pipes      = array();
			$started_at = microtime( true );
			$process    = self::open_process( $argv, $descriptors, $cwd, $env, false, $pipes );
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

			$stdout    = '';
			$stderr    = '';
			$timed_out = false;
			$deadline  = $started_at + max( 1, $timeout );

			while ( true ) {
				$status = proc_get_status( $process );

				if ( isset( $pipes[1] ) && is_resource( $pipes[1] ) ) {
					$chunk = stream_get_contents( $pipes[1] );
					if ( is_string( $chunk ) && '' !== $chunk ) {
						$stdout .= $chunk;
					}
				}
				if ( isset( $pipes[2] ) && is_resource( $pipes[2] ) ) {
					$chunk = stream_get_contents( $pipes[2] );
					if ( is_string( $chunk ) && '' !== $chunk ) {
						$stderr .= $chunk;
					}
				}

				if ( ! is_array( $status ) || false === $status['running'] ) {
					break;
				}
				if ( microtime( true ) >= $deadline ) {
					$timed_out = true;
					proc_terminate( $process, 15 );
					usleep( 100000 );
					$status = proc_get_status( $process );
					if ( is_array( $status ) && true === $status['running'] ) {
						proc_terminate( $process, 9 );
					}
					break;
				}

				usleep( 20000 );
			}

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
				fclose( $pipes[ $fd ] );
			}

			$exit_code   = proc_close( $process );
			$duration_ms = (int) round( ( microtime( true ) - $started_at ) * 1000 );

			if ( $timed_out ) {
				return new WP_Error( 'wp_coding_agents_cli_dispatch_timeout', sprintf( 'CLI channel "%s" exceeded the %d second timeout.', $channel, $timeout ), array( 'channel' => $channel, 'recipient' => $recipient, 'stdout' => self::truncate_output( $stdout ), 'stderr' => self::truncate_output( $stderr ), 'duration_ms' => $duration_ms ) );
			}

			if ( 0 !== $exit_code ) {
				return new WP_Error( 'wp_coding_agents_cli_dispatch_nonzero_exit', sprintf( 'CLI channel "%s" exited with code %d.', $channel, $exit_code ), array( 'channel' => $channel, 'recipient' => $recipient, 'exit_code' => $exit_code, 'stdout' => self::truncate_output( $stdout ), 'stderr' => self::truncate_output( $stderr ), 'duration_ms' => $duration_ms ) );
			}

			return array(
				'sent'       => true,
				'channel'    => $channel,
				'recipient'  => $recipient,
				'message_id' => null,
				'metadata'   => array(
					'mode'        => 'sync',
					'exit_code'   => $exit_code,
					'duration_ms' => $duration_ms,
					'stdout'      => self::truncate_output( $stdout ),
					'stderr'      => self::truncate_output( $stderr ),
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
		private static function open_process( array $argv, array $descriptors, ?string $cwd, ?array $env, bool $detached, array &$pipes = array() ) {
			if ( ! function_exists( 'proc_open' ) ) {
				return new WP_Error( 'wp_coding_agents_cli_dispatch_no_proc_open', 'proc_open is not available on this host.' );
			}

			$options = array();
			if ( $detached ) {
				$options['start_new_session'] = true;
			}

			$process = @proc_open( $argv, $descriptors, $pipes, $cwd, $env, $options );
			if ( ! is_resource( $process ) ) {
				return new WP_Error( 'wp_coding_agents_cli_dispatch_spawn_failed', sprintf( 'Failed to spawn CLI process "%s".', $argv[0] ?? '' ) );
			}

			return $process;
		}

		/**
		 * @param array<string, string> $configured Configured env map.
		 * @return array<string, string>
		 */
		private static function build_env_map( array $configured ): array {
			$env         = array();
			$parent_path = getenv( 'PATH' );
			if ( is_string( $parent_path ) && '' !== $parent_path ) {
				$env['PATH'] = $parent_path;
			}

			foreach ( $configured as $key => $value ) {
				$env[ $key ] = $value;
			}

			return $env;
		}

		private static function truncate_output( string $output ): string {
			$limit = 8192;
			if ( strlen( $output ) <= $limit ) {
				return $output;
			}

			return substr( $output, 0, $limit ) . "\n[...truncated]";
		}
	}
}

WpCodingAgents_Cli_Channel_Transport::register();
