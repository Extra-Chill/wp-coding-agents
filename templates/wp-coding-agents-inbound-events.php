<?php
/**
 * Plugin Name: wp-coding-agents - inbound event bridge
 * Description: Durable, provider-neutral ingress queue for signed inbound events. Managed by wp-coding-agents.
 *
 * Adapters register through `wp_coding_agents_inbound_event_adapters`. Each
 * adapter receives a WP_REST_Request and must authenticate it before returning
 * either a WP_Error, an immediate `response`, or a normalized event array:
 * source, external_id, type, conversation_id, runtime_id, message, attributes,
 * and optional attachments. Authentication material
 * remains in the request and is never passed to the queue or diagnostics.
 */

defined( 'ABSPATH' ) || exit;

if ( ! class_exists( 'WpCodingAgents_Inbound_Events', false ) ) {
	class WpCodingAgents_Inbound_Events {
		private const TABLE_SUFFIX = 'wp_coding_agents_inbound_events';
		private const CONVERSATIONS_SUFFIX = 'wp_coding_agents_runtime_conversations';
		private const SCHEMA_VERSION = 3;
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
			$sql = "CREATE TABLE {$table} (id bigint unsigned NOT NULL AUTO_INCREMENT, source varchar(64) NOT NULL, external_id varchar(191) NOT NULL, runtime_id varchar(191) NOT NULL DEFAULT '', envelope longtext NOT NULL, status varchar(16) NOT NULL DEFAULT 'queued', attempts int unsigned NOT NULL DEFAULT 0, available_at datetime NOT NULL, lease_token varchar(64) NULL, lease_expires_at datetime NULL, created_at datetime NOT NULL, updated_at datetime NOT NULL, PRIMARY KEY (id), UNIQUE KEY source_external (source, external_id), KEY claim (runtime_id, status, available_at, lease_expires_at)) {$charset};";
			$conversations = self::conversations_table();
			$conversations_sql = "CREATE TABLE {$conversations} (id bigint unsigned NOT NULL AUTO_INCREMENT, session_id varchar(191) NOT NULL, runtime_id varchar(191) NOT NULL, runtime_conversation_id varchar(191) NOT NULL, created_at datetime NOT NULL, updated_at datetime NOT NULL, PRIMARY KEY (id), UNIQUE KEY session (session_id), KEY runtime (runtime_id)) {$charset};";
			if ( ! function_exists( 'dbDelta' ) ) { require_once ABSPATH . 'wp-admin/includes/upgrade.php'; }
			dbDelta( $sql );
			dbDelta( $conversations_sql );
			if ( $table === $wpdb->get_var( $wpdb->prepare( 'SHOW TABLES LIKE %s', $table ) ) && $conversations === $wpdb->get_var( $wpdb->prepare( 'SHOW TABLES LIKE %s', $conversations ) ) ) {
				self::backfill_runtime_ids();
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
			$queued = self::submit( $result );
			if ( is_wp_error( $queued ) ) { return $queued; }
			if ( is_wp_error( $queued['wake'] ) ) { return $queued['wake']; }
			return rest_ensure_response( array( 'accepted' => true, 'duplicate' => ! $queued['new'] ) );
		}

		/**
		 * Validate, durably queue, and schedule the runtime wake for one event.
		 *
		 * The event is durable once this returns an array; a failed wake carries
		 * its WP_Error in `wake` so each caller decides whether that is fatal.
		 *
		 * @return array{id:int,new:bool,wake:true|WP_Error}|WP_Error
		 */
		public static function submit( array $event ) {
			$normalized = self::normalize( $event );
			if ( is_wp_error( $normalized ) ) { return $normalized; }
			$queued = self::enqueue( $normalized );
			if ( is_wp_error( $queued ) ) { return $queued; }
			if ( $queued['new'] ) {
				do_action( 'wp_coding_agents_inbound_event_queued', $normalized, $queued['id'] );
			}
			$queued['wake'] = self::schedule_runtime_wake( $normalized['runtime_id'] );
			return $queued;
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
			$attachments = $event['attachments'] ?? array();
			if ( ! is_array( $attachments ) || count( $attachments ) > 8 ) { return new WP_Error( 'wp_coding_agents_inbound_invalid_event', 'Verified event has invalid attachments.', array( 'status' => 400 ) ); }
			$clean_attachments = array();
			foreach ( $attachments as $attachment ) {
				if ( ! is_array( $attachment ) || array() === $attachment ) { return new WP_Error( 'wp_coding_agents_inbound_invalid_event', 'Verified event has invalid attachments.', array( 'status' => 400 ) ); }
				$clean_attachments[] = $attachment;
			}
			if ( array() !== $clean_attachments ) { $normalized['attachments'] = $clean_attachments; }
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
		public static function adapter_config( string $adapter ): array {
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
			$inserted = $wpdb->query( $wpdb->prepare( 'INSERT IGNORE INTO ' . self::table() . ' (source, external_id, runtime_id, envelope, available_at, created_at, updated_at) VALUES (%s, %s, %s, %s, %s, %s, %s)', $event['source'], $event['external_id'], $event['runtime_id'], $json, $now, $now, $now ) );
			if ( false === $inserted ) { return new WP_Error( 'wp_coding_agents_inbound_queue_failed', 'Could not queue event.' ); }
			if ( 1 === $inserted ) { return array( 'id' => (int) $wpdb->insert_id, 'new' => true ); }
			$id = $wpdb->get_var( $wpdb->prepare( 'SELECT id FROM ' . self::table() . ' WHERE source = %s AND external_id = %s', $event['source'], $event['external_id'] ) );
			return array( 'id' => (int) $id, 'new' => false );
		}

		/** Atomically recover stale leases and claim one available event. */
		public static function claim( ?string $runtime_id = null ): ?array {
			global $wpdb;
			$now = current_time( 'mysql', true ); $token = wp_generate_uuid4(); $until = gmdate( 'Y-m-d H:i:s', time() + self::LEASE_SECONDS );
			$wpdb->query( $wpdb->prepare( "UPDATE " . self::table() . " SET status = 'queued', lease_token = NULL, lease_expires_at = NULL, updated_at = %s WHERE status = 'leased' AND lease_expires_at < %s", $now, $now ) );
			$owner = null === $runtime_id ? "runtime_id <> ''" : $wpdb->prepare( 'runtime_id = %s', $runtime_id );
			$row = $wpdb->get_row( $wpdb->prepare( "SELECT id FROM " . self::table() . " WHERE {$owner} AND status = 'queued' AND available_at <= %s ORDER BY id ASC LIMIT 1", $now ), ARRAY_A );
			if ( ! is_array( $row ) ) { return null; }
			$changed = $wpdb->query( $wpdb->prepare( "UPDATE " . self::table() . " SET status = 'leased', lease_token = %s, lease_expires_at = %s, attempts = attempts + 1, updated_at = %s WHERE id = %d AND status = 'queued' AND {$owner}", $token, $until, $now, $row['id'] ) );
			if ( 1 !== $changed ) { return null; }
			$event = $wpdb->get_row( $wpdb->prepare( 'SELECT id, envelope FROM ' . self::table() . ' WHERE id = %d AND lease_token = %s', $row['id'], $token ), ARRAY_A );
			$envelope = is_array( $event ) ? json_decode( $event['envelope'], true ) : null;
			return is_array( $envelope ) ? array( 'id' => (int) $row['id'], 'lease_token' => $token, 'event' => $envelope ) : null;
		}

		public static function acknowledge( int $id, string $token ): bool { global $wpdb; return 1 === $wpdb->query( $wpdb->prepare( "UPDATE " . self::table() . " SET status = 'acked', lease_token = NULL, lease_expires_at = NULL, updated_at = %s WHERE id = %d AND status = 'leased' AND lease_token = %s", current_time( 'mysql', true ), $id, $token ) ); }
		public static function retry( int $id, string $token, int $delay = 0 ): bool { global $wpdb; $at = gmdate( 'Y-m-d H:i:s', time() + max( 0, $delay ) ); return 1 === $wpdb->query( $wpdb->prepare( "UPDATE " . self::table() . " SET status = 'queued', lease_token = NULL, lease_expires_at = NULL, available_at = %s, updated_at = %s WHERE id = %d AND status = 'leased' AND lease_token = %s", $at, current_time( 'mysql', true ), $id, $token ) ); }
		private static function table(): string { global $wpdb; return $wpdb->prefix . self::TABLE_SUFFIX; }
		public static function conversations_table(): string { global $wpdb; return $wpdb->prefix . self::CONVERSATIONS_SUFFIX; }
		public static function valid_runtime_id( string $runtime_id ): bool { return (bool) preg_match( '/^[A-Za-z0-9][A-Za-z0-9._-]{0,190}$/', $runtime_id ); }

		/** Backfill v1 rows only when their persisted envelope has a valid owner. */
		private static function backfill_runtime_ids(): void {
			global $wpdb;
			$rows = $wpdb->get_results( "SELECT id, envelope FROM " . self::table() . " WHERE runtime_id = ''", ARRAY_A );
			foreach ( is_array( $rows ) ? $rows : array() as $row ) {
				$envelope = json_decode( $row['envelope'] ?? '', true );
				$runtime_id = is_array( $envelope ) && is_string( $envelope['runtime_id'] ?? null ) ? $envelope['runtime_id'] : '';
				if ( self::valid_runtime_id( $runtime_id ) ) { $wpdb->query( $wpdb->prepare( 'UPDATE ' . self::table() . ' SET runtime_id = %s WHERE id = %d AND runtime_id = %s', $runtime_id, $row['id'], '' ) ); }
			}
		}

		public static function cli( array $args, array $assoc ): void {
			$verb = $args[0] ?? '';
			$runtime_id = isset( $assoc['runtime-id'] ) ? (string) $assoc['runtime-id'] : null;
			if ( null !== $runtime_id && ! self::valid_runtime_id( $runtime_id ) ) { WP_CLI::halt( 1 ); }
			if ( 'claim' === $verb ) { $claim = self::claim( $runtime_id ); $claim ? WP_CLI::print_value( $claim, array( 'format' => $assoc['format'] ?? 'json' ) ) : WP_CLI::halt( 1 ); return; }
			if ( 'poll' === $verb ) { if ( null === $runtime_id ) { WP_CLI::halt( 1 ); } $claim = self::claim( $runtime_id ); WP_CLI::print_value( $claim ? array( 'status' => 'claimed', 'claim' => $claim ) : array( 'status' => 'empty' ), array( 'format' => $assoc['format'] ?? 'json' ) ); return; }
			$id = isset( $args[1] ) ? (int) $args[1] : 0; $token = isset( $assoc['lease-token'] ) ? (string) $assoc['lease-token'] : '';
			$ok = 'ack' === $verb ? self::acknowledge( $id, $token ) : ( 'retry' === $verb ? self::retry( $id, $token, isset( $assoc['delay'] ) ? (int) $assoc['delay'] : 0 ) : false );
			$ok ? WP_CLI::success( $verb . 'nowledged.' ) : WP_CLI::halt( 1 );
		}
	}
}

/**
 * Runtime-backed `agents/chat` routing (agents-api `wp_agent_chat_handler`).
 *
 * Only agents explicitly listed in installer-written config are claimed: the
 * `runtime-chat` entry of the inbound adapter config (filter or constant) maps
 * agent slugs to the runtime IDs that claim their queued events, for example
 * `array( 'runtime-chat' => array( 'agents' => array( '<agent-slug>' => '<runtime-id>' ) ) )`.
 * Vendor and runtime names live only in that config. Unconfigured agents are
 * untouched. Each accepted turn validates permission as the authenticated WP
 * user and is durably queued as one inbound event with conversation_id = the
 * WP session_id; the runtime claims it with the existing claim/ack contract.
 * The WP session is durably mapped to a runtime conversation ID on the first
 * turn; a continuing session without a mapping fails closed. Cancellation
 * flows through the same queue via `wp_agent_chat_run_cancel_handler`.
 */
if ( ! class_exists( 'WpCodingAgents_Runtime_Chat', false ) ) {
	class WpCodingAgents_Runtime_Chat {
		private const SOURCE = 'agents-chat';

		public static function register(): void {
			add_filter( 'wp_agent_chat_handler', array( self::class, 'route' ), 10, 2 );
			add_filter( 'wp_agent_chat_run_cancel_handler', array( self::class, 'route_cancel' ), 10, 2 );
		}

		/** @param mixed $handler @return mixed */
		public static function route( $handler, array $input ) {
			if ( null !== $handler ) { return $handler; }
			$agent = self::text( $input['agent'] ?? null );
			return null !== $agent && null !== self::agent_runtime( $agent ) ? array( self::class, 'handle' ) : $handler;
		}

		/** Claim cancellation only for sessions this layer durably mapped to a configured runtime. @param mixed $handler @return mixed */
		public static function route_cancel( $handler, array $input ) {
			if ( null !== $handler ) { return $handler; }
			$session_id = self::text( $input['session_id'] ?? null );
			$mapping = null === $session_id ? null : self::conversation_mapping( $session_id );
			return is_array( $mapping ) && in_array( $mapping['runtime_id'], self::configured_runtime_ids(), true ) ? array( self::class, 'handle_cancel' ) : $handler;
		}

		/** @return array<string,mixed>|WP_Error */
		public static function handle( array $input ) {
			$agent = self::text( $input['agent'] ?? null );
			$runtime_id = null === $agent ? null : self::agent_runtime( $agent );
			if ( null === $runtime_id ) { return new WP_Error( 'wp_coding_agents_runtime_chat_not_configured', 'Agent is not configured for a managed runtime.', array( 'status' => 404 ) ); }
			$actor = self::authenticated_actor( $input );
			if ( is_wp_error( $actor ) ) { return $actor; }
			$run_id = self::text( $input['run_id'] ?? null );
			$message = self::text( $input['message'] ?? null );
			if ( null === $run_id || strlen( $run_id ) > 180 || null === $message ) { return new WP_Error( 'wp_coding_agents_runtime_chat_invalid_turn', 'Runtime-backed chat requires a bounded run_id and a message.', array( 'status' => 400 ) ); }
			$session_id = self::text( $input['session_id'] ?? null );
			$new_session = null === $session_id;
			$session_id = $session_id ?? 'wpca-' . wp_generate_uuid4();
			if ( strlen( $session_id ) > 191 ) { return new WP_Error( 'wp_coding_agents_runtime_chat_invalid_turn', 'Runtime-backed chat requires a bounded session_id.', array( 'status' => 400 ) ); }
			$mapping = self::ensure_conversation_mapping( $session_id, $runtime_id, $new_session );
			if ( is_wp_error( $mapping ) ) { return $mapping; }
			$attachments = array();
			foreach ( is_array( $input['attachments'] ?? null ) ? $input['attachments'] : array() as $attachment ) {
				if ( is_array( $attachment ) && array() !== $attachment ) { $attachments[] = $attachment; }
			}
			$queued = WpCodingAgents_Inbound_Events::submit( array(
				'source' => self::SOURCE,
				'external_id' => 'turn-' . $run_id,
				'type' => 'chat_message',
				'conversation_id' => $session_id,
				'runtime_id' => $runtime_id,
				'message' => $message,
				'attachments' => $attachments,
				'attributes' => array( 'agent' => $agent, 'run_id' => $run_id, 'actor_user_id' => (string) $actor, 'runtime_conversation_id' => $mapping['runtime_conversation_id'] ),
			) );
			if ( is_wp_error( $queued ) ) { return $queued; }
			// The event is durable; a failed wake is repaired by runtime polling, so the pending turn still returns.
			return array(
				'session_id' => $session_id,
				'reply' => '',
				'completed' => false,
				'metadata' => array( 'wp_coding_agents' => array( 'pending' => true, 'runtime_id' => $runtime_id, 'event_id' => $queued['id'], 'duplicate' => ! $queued['new'], 'runtime_conversation_id' => $mapping['runtime_conversation_id'] ) ),
			);
		}

		/** @return array<string,mixed>|WP_Error */
		public static function handle_cancel( array $input ) {
			$actor = self::authenticated_actor( null );
			if ( is_wp_error( $actor ) ) { return $actor; }
			$run_id = self::text( $input['run_id'] ?? null );
			$session_id = self::text( $input['session_id'] ?? null );
			if ( null === $run_id || strlen( $run_id ) > 180 || null === $session_id || strlen( $session_id ) > 191 ) { return new WP_Error( 'wp_coding_agents_runtime_chat_invalid_cancel', 'Runtime-backed cancellation requires a bounded run_id and session_id.', array( 'status' => 400 ) ); }
			$mapping = self::conversation_mapping( $session_id );
			if ( ! is_array( $mapping ) || ! in_array( $mapping['runtime_id'], self::configured_runtime_ids(), true ) ) { return new WP_Error( 'wp_coding_agents_runtime_chat_unmapped', 'No durable runtime conversation mapping exists for this session.', array( 'status' => 409 ) ); }
			$queued = WpCodingAgents_Inbound_Events::submit( array(
				'source' => self::SOURCE,
				'external_id' => 'cancel-' . $run_id,
				'type' => 'chat_cancel',
				'conversation_id' => $session_id,
				'runtime_id' => $mapping['runtime_id'],
				'message' => 'cancel',
				'attributes' => array( 'run_id' => $run_id, 'actor_user_id' => (string) $actor, 'runtime_conversation_id' => $mapping['runtime_conversation_id'] ),
			) );
			if ( is_wp_error( $queued ) ) { return $queued; }
			return array( 'run_id' => $run_id, 'session_id' => $session_id, 'status' => 'cancelling' );
		}

		/** @return array{runtime_id:string,runtime_conversation_id:string}|null */
		public static function conversation_mapping( string $session_id ): ?array {
			global $wpdb;
			$row = $wpdb->get_row( $wpdb->prepare( 'SELECT runtime_id, runtime_conversation_id FROM ' . WpCodingAgents_Inbound_Events::conversations_table() . ' WHERE session_id = %s', $session_id ), ARRAY_A );
			if ( ! is_array( $row ) || ! is_string( $row['runtime_id'] ?? null ) || ! is_string( $row['runtime_conversation_id'] ?? null ) ) { return null; }
			return array( 'runtime_id' => $row['runtime_id'], 'runtime_conversation_id' => $row['runtime_conversation_id'] );
		}

		/** First turn creates the durable mapping; a continuing session without one, or owned by another runtime, fails closed. @return array{runtime_id:string,runtime_conversation_id:string}|WP_Error */
		private static function ensure_conversation_mapping( string $session_id, string $runtime_id, bool $new_session ) {
			global $wpdb;
			$existing = self::conversation_mapping( $session_id );
			if ( null === $existing && $new_session ) {
				$now = current_time( 'mysql', true );
				$created = $wpdb->query( $wpdb->prepare( 'INSERT IGNORE INTO ' . WpCodingAgents_Inbound_Events::conversations_table() . ' (session_id, runtime_id, runtime_conversation_id, created_at, updated_at) VALUES (%s, %s, %s, %s, %s)', $session_id, $runtime_id, 'rc-' . wp_generate_uuid4(), $now, $now ) );
				if ( false === $created ) { return new WP_Error( 'wp_coding_agents_runtime_chat_mapping_failed', 'Could not persist the runtime conversation mapping.' ); }
				$existing = self::conversation_mapping( $session_id );
			}
			if ( ! is_array( $existing ) ) { return new WP_Error( 'wp_coding_agents_runtime_chat_unmapped', 'No durable runtime conversation mapping exists for this session.', array( 'status' => 409 ) ); }
			if ( $existing['runtime_id'] !== $runtime_id ) { return new WP_Error( 'wp_coding_agents_runtime_chat_unmapped', 'The session is durably mapped to a different runtime.', array( 'status' => 409 ) ); }
			return $existing;
		}

		/**
		 * Validate the turn as the authenticated WordPress user, fail closed otherwise.
		 *
		 * @param array<mixed>|null $chat_input Canonical chat input to re-check through the agents-api gate, when present.
		 * @return int|WP_Error
		 */
		private static function authenticated_actor( ?array $chat_input ) {
			$user_id = function_exists( 'get_current_user_id' ) ? (int) get_current_user_id() : 0;
			if ( $user_id <= 0 ) { return new WP_Error( 'wp_coding_agents_runtime_chat_forbidden', 'Runtime-backed chat requires an authenticated WordPress user.', array( 'status' => 403 ) ); }
			if ( null !== $chat_input && function_exists( 'AgentsAPI\\AI\\Channels\\agents_chat_permission' ) && true !== \AgentsAPI\AI\Channels\agents_chat_permission( $chat_input ) ) {
				return new WP_Error( 'wp_coding_agents_runtime_chat_forbidden', 'The authenticated WordPress user may not chat with this agent.', array( 'status' => 403 ) );
			}
			return $user_id;
		}

		private static function agent_runtime( string $agent ): ?string {
			return self::configured_agents()[ $agent ] ?? null;
		}

		/** Installer-written config only: agent slug to runtime ID. @return array<string,string> */
		private static function configured_agents(): array {
			$config = WpCodingAgents_Inbound_Events::adapter_config( 'runtime-chat' );
			$agents = is_array( $config['agents'] ?? null ) ? $config['agents'] : array();
			$configured = array();
			foreach ( $agents as $slug => $runtime_id ) {
				if ( is_array( $runtime_id ) ) { $runtime_id = $runtime_id['runtime_id'] ?? null; }
				if ( ! is_string( $slug ) || ! preg_match( '/^[a-z0-9][a-z0-9_-]{0,190}$/', $slug ) || ! is_string( $runtime_id ) || ! WpCodingAgents_Inbound_Events::valid_runtime_id( $runtime_id ) ) { continue; }
				$configured[ $slug ] = $runtime_id;
			}
			return $configured;
		}

		/** @return string[] */
		private static function configured_runtime_ids(): array {
			return array_values( array_unique( array_values( self::configured_agents() ) ) );
		}

		/** @param mixed $value */
		private static function text( $value ): ?string {
			if ( ! is_scalar( $value ) ) { return null; }
			$value = trim( (string) $value );
			return '' === $value ? null : $value;
		}
	}
}

WpCodingAgents_Inbound_Events::register();
WpCodingAgents_Runtime_Chat::register();
