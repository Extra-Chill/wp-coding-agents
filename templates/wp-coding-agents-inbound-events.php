<?php
/**
 * Plugin Name: wp-coding-agents - inbound event bridge
 * Description: Durable, provider-neutral ingress queue for signed inbound events. Managed by wp-coding-agents.
 *
 * Adapters register through `wp_coding_agents_inbound_event_adapters`. Each
 * adapter receives a WP_REST_Request and must authenticate it before returning
 * either a WP_Error, an immediate `response`, or a normalized event array:
 * source, external_id, type, conversation_id, runtime_id, message, attributes. Authentication material
 * remains in the request and is never passed to the queue or diagnostics.
 */

defined( 'ABSPATH' ) || exit;

if ( ! class_exists( 'WpCodingAgents_Inbound_Events', false ) ) {
	class WpCodingAgents_Inbound_Events {
		private const TABLE_SUFFIX = 'wp_coding_agents_inbound_events';
		private const SCHEMA_VERSION = 1;
		private const SCHEMA_OPTION = 'wp_coding_agents_inbound_events_schema';
		private const LEASE_SECONDS = 300;

		public static function register(): void {
			add_action( 'rest_api_init', array( self::class, 'routes' ) );
			add_action( 'plugins_loaded', array( self::class, 'install' ) );
			add_action( 'wp_coding_agents_runtime_wake', array( self::class, 'wake_runtime' ), 10, 2 );
			if ( defined( 'WP_CLI' ) && WP_CLI ) {
				WP_CLI::add_command( 'coding-agents inbound', array( self::class, 'cli' ) );
			}
		}

		public static function install(): void {
			global $wpdb;
			if ( ! isset( $wpdb ) || ! isset( $wpdb->prefix ) ) { return; }
			if ( (int) get_option( self::SCHEMA_OPTION, 0 ) >= self::SCHEMA_VERSION ) { return; }
			$table = self::table();
			$charset = method_exists( $wpdb, 'get_charset_collate' ) ? $wpdb->get_charset_collate() : '';
			$sql = "CREATE TABLE {$table} (id bigint unsigned NOT NULL AUTO_INCREMENT, source varchar(64) NOT NULL, external_id varchar(191) NOT NULL, envelope longtext NOT NULL, status varchar(16) NOT NULL DEFAULT 'queued', attempts int unsigned NOT NULL DEFAULT 0, available_at datetime NOT NULL, lease_token varchar(64) NULL, lease_expires_at datetime NULL, created_at datetime NOT NULL, updated_at datetime NOT NULL, PRIMARY KEY (id), UNIQUE KEY source_external (source, external_id), KEY claim (status, available_at, lease_expires_at)) {$charset};";
			if ( ! function_exists( 'dbDelta' ) ) { require_once ABSPATH . 'wp-admin/includes/upgrade.php'; }
			dbDelta( $sql );
			if ( $table === $wpdb->get_var( $wpdb->prepare( 'SHOW TABLES LIKE %s', $table ) ) ) {
				update_option( self::SCHEMA_OPTION, self::SCHEMA_VERSION, false );
			}
		}

		public static function routes(): void {
			register_rest_route( 'wp-coding-agents/v1', '/inbound/(?P<adapter>[a-z0-9_-]+)', array(
				'methods' => 'POST', 'callback' => array( self::class, 'ingress' ), 'permission_callback' => '__return_true',
			) );
		}

		/** The adapter owns signature verification and URL-verification replies. */
		public static function ingress( WP_REST_Request $request ) {
			$adapters = apply_filters( 'wp_coding_agents_inbound_event_adapters', array(), $request );
			$adapter = $adapters[ $request['adapter'] ] ?? null;
			if ( 'slack' === $request['adapter'] && ! is_callable( $adapter ) ) { $adapter = array( self::class, 'slack' ); }
			if ( ! is_callable( $adapter ) ) { return new WP_Error( 'wp_coding_agents_inbound_unknown_adapter', 'Unknown inbound adapter.', array( 'status' => 404 ) ); }
			$result = $adapter( $request );
			if ( is_wp_error( $result ) ) { return $result; }
			if ( ! is_array( $result ) ) { return new WP_Error( 'wp_coding_agents_inbound_invalid_adapter', 'Adapter returned no verified event.', array( 'status' => 400 ) ); }
			if ( isset( $result['response'] ) ) { return rest_ensure_response( $result['response'] ); }
			$event = self::normalize( $result );
			if ( is_wp_error( $event ) ) { return $event; }
			$queued = self::enqueue( $event );
			if ( is_wp_error( $queued ) ) { return $queued; }
			if ( $queued['new'] ) {
				do_action( 'wp_coding_agents_inbound_event_queued', $event, $queued['id'] );
			}
			$wake = self::schedule_runtime_wake( $event['runtime_id'] );
			if ( is_wp_error( $wake ) ) { return $wake; }
			return rest_ensure_response( array( 'accepted' => true, 'duplicate' => ! $queued['new'] ) );
		}

		/** Dispatch the runtime request only from the asynchronous cron callback. */
		public static function wake_runtime( string $runtime_id, string $wake_reason ): void {
			do_action( 'wp_coding_agents_runtime_requested', $runtime_id, $wake_reason );
		}

		/** @return true|WP_Error */
		private static function schedule_runtime_wake( string $runtime_id ) {
			$hook = 'wp_coding_agents_runtime_wake';
			$args = array( $runtime_id, 'inbound_event' );
			if ( wp_next_scheduled( $hook, $args ) ) { return true; }
			$scheduled = wp_schedule_single_event( time(), $hook, $args, true );
			if ( is_wp_error( $scheduled ) || false === $scheduled ) {
				return new WP_Error( 'wp_coding_agents_inbound_wake_unavailable', 'Inbound event queued; runtime wake will be retried.', array( 'status' => 503 ) );
			}
			if ( function_exists( 'spawn_cron' ) ) { spawn_cron( time() ); }
			return true;
		}

		/** @return array<string,string|array<string,string>>|WP_Error */
		public static function normalize( array $event ) {
			$normalized = array();
			foreach ( array( 'source', 'external_id', 'type', 'conversation_id', 'runtime_id', 'message' ) as $key ) {
				$value = $event[ $key ] ?? null;
				if ( ! is_scalar( $value ) || '' === trim( (string) $value ) || strlen( (string) $value ) > 65535 ) { return new WP_Error( 'wp_coding_agents_inbound_invalid_event', 'Verified event is missing a required field.', array( 'status' => 400 ) ); }
				$normalized[ $key ] = (string) $value;
			}
			if ( ! preg_match( '/^[a-z0-9][a-z0-9_-]{0,63}$/', $normalized['source'] ) || strlen( $normalized['external_id'] ) > 191 || strlen( $normalized['runtime_id'] ) > 191 ) { return new WP_Error( 'wp_coding_agents_inbound_invalid_event', 'Verified event has invalid identifiers.', array( 'status' => 400 ) ); }
			$attributes = $event['attributes'] ?? array();
			if ( ! is_array( $attributes ) || count( $attributes ) > 8 ) { return new WP_Error( 'wp_coding_agents_inbound_invalid_event', 'Verified event has invalid attributes.', array( 'status' => 400 ) ); }
			$clean_attributes = array();
			foreach ( $attributes as $key => $value ) {
				if ( ! is_string( $key ) || ! preg_match( '/^[a-z][a-z0-9_]{0,63}$/', $key ) || ! is_string( $value ) || '' === $value || strlen( $value ) > 191 ) { return new WP_Error( 'wp_coding_agents_inbound_invalid_event', 'Verified event has invalid attributes.', array( 'status' => 400 ) ); }
				if ( in_array( $key, array( 'authorization', 'signature', 'signing_secret', 'token', 'raw_body', 'raw_payload' ), true ) ) { continue; }
				$clean_attributes[ $key ] = $value;
			}
			$normalized['attributes'] = $clean_attributes;
			$json = wp_json_encode( $normalized );
			if ( false === $json || strlen( $json ) > 8192 ) { return new WP_Error( 'wp_coding_agents_inbound_invalid_event', 'Verified event is too large.', array( 'status' => 400 ) ); }
			return $normalized;
		}

		/**
			 * Validate and normalize Slack's signed Events API request.
			 *
			 * Configuration comes only from the generic adapter-config filter, or the
			 * optional WP_CODING_AGENTS_INBOUND_EVENT_ADAPTER_CONFIG constant. Its
			 * `slack` entry contains signing_secret, runtime_id, allowed_team_ids, and
			 * allowed_channel_ids.
		 */
		public static function slack( WP_REST_Request $request ) {
			$config = self::adapter_config( 'slack' );
			$secret = $config['signing_secret'] ?? null;
			$runtime_id = $config['runtime_id'] ?? null;
			$allowed = $config['allowed_channel_ids'] ?? null;
			$teams = $config['allowed_team_ids'] ?? null;
			if ( ! is_string( $secret ) || '' === $secret || ! is_string( $runtime_id ) || '' === $runtime_id || ! self::valid_ids( $allowed, '/^[A-Z][A-Z0-9]{1,63}$/' ) || ! self::valid_ids( $teams, '/^T[A-Z0-9]{1,63}$/' ) ) { return new WP_Error( 'wp_coding_agents_inbound_not_configured', 'Inbound adapter is not configured.', array( 'status' => 404 ) ); }
			$timestamp = $request->get_header( 'x-slack-request-timestamp' );
			$signature = $request->get_header( 'x-slack-signature' );
			$body = $request->get_body();
			if ( ! ctype_digit( $timestamp ) || abs( time() - (int) $timestamp ) > 300 || ! is_string( $signature ) ) { return new WP_Error( 'wp_coding_agents_inbound_invalid_signature', 'Invalid signed request.', array( 'status' => 403 ) ); }
			$expected = 'v0=' . hash_hmac( 'sha256', 'v0:' . $timestamp . ':' . $body, $secret );
			if ( ! hash_equals( $expected, $signature ) ) { return new WP_Error( 'wp_coding_agents_inbound_invalid_signature', 'Invalid signed request.', array( 'status' => 403 ) ); }
			$payload = json_decode( $body, true );
			if ( ! is_array( $payload ) ) { return new WP_Error( 'wp_coding_agents_inbound_invalid_payload', 'Invalid event payload.', array( 'status' => 400 ) ); }
			if ( 'url_verification' === ( $payload['type'] ?? null ) && is_string( $payload['challenge'] ?? null ) ) { return array( 'response' => array( 'challenge' => $payload['challenge'] ) ); }
			$event = $payload['event'] ?? null;
			if ( 'event_callback' !== ( $payload['type'] ?? null ) || ! is_array( $event ) ) { return array( 'response' => array( 'accepted' => true ) ); }
			$event_type = $event['type'] ?? null;
			if ( ! in_array( $event_type, array( 'message', 'app_mention' ), true ) ) { return array( 'response' => array( 'accepted' => true ) ); }
			$team = $payload['team_id'] ?? null;
			if ( ! is_string( $team ) || ! preg_match( '/^T[A-Z0-9]{1,63}$/', $team ) || ! in_array( $team, $teams, true ) ) { return array( 'response' => array( 'accepted' => true ) ); }
			if ( isset( $event['bot_id'] ) || ! empty( $event['subtype'] ) ) { return array( 'response' => array( 'accepted' => true ) ); }
			$channel = $event['channel'] ?? null;
			$actor = $event['user'] ?? null;
			$message_ts = $event['ts'] ?? null;
			$thread = $event['thread_ts'] ?? $event['ts'] ?? null;
			if ( ! is_string( $channel ) || ! preg_match( '/^[A-Z0-9]{1,64}$/', $channel ) || ! in_array( $channel, $allowed, true ) ) { return array( 'response' => array( 'accepted' => true ) ); }
			if ( ! is_string( $actor ) || ! preg_match( '/^[UW][A-Z0-9]{1,63}$/', $actor ) || ! is_string( $message_ts ) || ! preg_match( '/^\d{1,20}\.\d{1,6}$/', $message_ts ) || ! is_string( $thread ) || ! preg_match( '/^\d{1,20}\.\d{1,6}$/', $thread ) || ! is_string( $payload['event_id'] ?? null ) || ! preg_match( '/^[A-Za-z0-9_-]{1,191}$/', $payload['event_id'] ) || ! is_string( $event['text'] ?? null ) || '' === trim( $event['text'] ) ) { return new WP_Error( 'wp_coding_agents_inbound_invalid_payload', 'Invalid event payload.', array( 'status' => 400 ) ); }
			return array( 'source' => 'slack', 'external_id' => $payload['event_id'], 'type' => $event_type, 'conversation_id' => $channel . ':' . $thread, 'runtime_id' => $runtime_id, 'message' => $event['text'], 'attributes' => array( 'team_id' => $team, 'channel_id' => $channel, 'actor_id' => $actor, 'message_ts' => $message_ts, 'thread_ts' => $thread ) );
		}

		/** @param mixed $ids */
		private static function valid_ids( $ids, string $pattern ): bool {
			if ( ! is_array( $ids ) || empty( $ids ) ) { return false; }
			foreach ( $ids as $id ) { if ( ! is_string( $id ) || ! preg_match( $pattern, $id ) ) { return false; } }
			return true;
		}

		/** @return array<string,mixed> */
		private static function adapter_config( string $adapter ): array {
			$config = defined( 'WP_CODING_AGENTS_INBOUND_EVENT_ADAPTER_CONFIG' ) ? constant( 'WP_CODING_AGENTS_INBOUND_EVENT_ADAPTER_CONFIG' ) : array();
			$config = is_array( $config ) ? $config : array();
			$config = apply_filters( 'wp_coding_agents_inbound_event_adapter_config', $config, $adapter );
			$value = $config[ $adapter ] ?? array();
			return is_array( $value ) ? $value : array();
		}

		/** @return array{id:int,new:bool}|WP_Error */
		public static function enqueue( array $event ) {
			global $wpdb;
			$now = current_time( 'mysql', true );
			$json = wp_json_encode( $event );
			if ( false === $json ) { return new WP_Error( 'wp_coding_agents_inbound_encode_failed', 'Could not queue event.' ); }
			$inserted = $wpdb->query( $wpdb->prepare( 'INSERT IGNORE INTO ' . self::table() . ' (source, external_id, envelope, available_at, created_at, updated_at) VALUES (%s, %s, %s, %s, %s, %s)', $event['source'], $event['external_id'], $json, $now, $now, $now ) );
			if ( false === $inserted ) { return new WP_Error( 'wp_coding_agents_inbound_queue_failed', 'Could not queue event.' ); }
			if ( 1 === $inserted ) { return array( 'id' => (int) $wpdb->insert_id, 'new' => true ); }
			$id = $wpdb->get_var( $wpdb->prepare( 'SELECT id FROM ' . self::table() . ' WHERE source = %s AND external_id = %s', $event['source'], $event['external_id'] ) );
			return array( 'id' => (int) $id, 'new' => false );
		}

		/** Atomically recover stale leases and claim one available event. */
		public static function claim(): ?array {
			global $wpdb;
			$now = current_time( 'mysql', true ); $token = wp_generate_uuid4(); $until = gmdate( 'Y-m-d H:i:s', time() + self::LEASE_SECONDS );
			$wpdb->query( $wpdb->prepare( "UPDATE " . self::table() . " SET status = 'queued', lease_token = NULL, lease_expires_at = NULL, updated_at = %s WHERE status = 'leased' AND lease_expires_at < %s", $now, $now ) );
			$row = $wpdb->get_row( $wpdb->prepare( "SELECT id FROM " . self::table() . " WHERE status = 'queued' AND available_at <= %s ORDER BY id ASC LIMIT 1", $now ), ARRAY_A );
			if ( ! is_array( $row ) ) { return null; }
			$changed = $wpdb->query( $wpdb->prepare( "UPDATE " . self::table() . " SET status = 'leased', lease_token = %s, lease_expires_at = %s, attempts = attempts + 1, updated_at = %s WHERE id = %d AND status = 'queued'", $token, $until, $now, $row['id'] ) );
			if ( 1 !== $changed ) { return null; }
			$event = $wpdb->get_row( $wpdb->prepare( 'SELECT id, envelope FROM ' . self::table() . ' WHERE id = %d AND lease_token = %s', $row['id'], $token ), ARRAY_A );
			$envelope = is_array( $event ) ? json_decode( $event['envelope'], true ) : null;
			return is_array( $envelope ) ? array( 'id' => (int) $row['id'], 'lease_token' => $token, 'event' => $envelope ) : null;
		}

		public static function acknowledge( int $id, string $token ): bool { global $wpdb; return 1 === $wpdb->query( $wpdb->prepare( "UPDATE " . self::table() . " SET status = 'acked', lease_token = NULL, lease_expires_at = NULL, updated_at = %s WHERE id = %d AND status = 'leased' AND lease_token = %s", current_time( 'mysql', true ), $id, $token ) ); }
		public static function retry( int $id, string $token, int $delay = 0 ): bool { global $wpdb; $at = gmdate( 'Y-m-d H:i:s', time() + max( 0, $delay ) ); return 1 === $wpdb->query( $wpdb->prepare( "UPDATE " . self::table() . " SET status = 'queued', lease_token = NULL, lease_expires_at = NULL, available_at = %s, updated_at = %s WHERE id = %d AND status = 'leased' AND lease_token = %s", $at, current_time( 'mysql', true ), $id, $token ) ); }
		private static function table(): string { global $wpdb; return $wpdb->prefix . self::TABLE_SUFFIX; }

		public static function cli( array $args, array $assoc ): void {
			$verb = $args[0] ?? '';
			if ( 'claim' === $verb ) { $claim = self::claim(); $claim ? WP_CLI::print_value( $claim, array( 'format' => $assoc['format'] ?? 'json' ) ) : WP_CLI::halt( 1 ); return; }
			if ( 'poll' === $verb ) { $claim = self::claim(); WP_CLI::print_value( $claim ? array( 'status' => 'claimed', 'claim' => $claim ) : array( 'status' => 'empty' ), array( 'format' => $assoc['format'] ?? 'json' ) ); return; }
			$id = isset( $args[1] ) ? (int) $args[1] : 0; $token = isset( $assoc['lease-token'] ) ? (string) $assoc['lease-token'] : '';
			$ok = 'ack' === $verb ? self::acknowledge( $id, $token ) : ( 'retry' === $verb ? self::retry( $id, $token, isset( $assoc['delay'] ) ? (int) $assoc['delay'] : 0 ) : false );
			$ok ? WP_CLI::success( $verb . 'nowledged.' ) : WP_CLI::halt( 1 );
		}
	}
}

WpCodingAgents_Inbound_Events::register();
