<?php
declare( strict_types=1 );
define( 'ABSPATH', __DIR__ . '/' );
define( 'ARRAY_A', 'ARRAY_A' );
class WP_Error { public function __construct( public string $code = '', public string $message = '', public mixed $data = null ) {} }
function is_wp_error( mixed $value ): bool { return $value instanceof WP_Error; }
function wp_json_encode( mixed $value ): string|false { return json_encode( $value ); }
function current_time( string $type, bool $gmt = false ): string { return gmdate( 'Y-m-d H:i:s' ); }
function wp_generate_uuid4(): string { static $n = 0; return 'lease-' . ++$n; }
function rest_ensure_response( mixed $value ): mixed { return $value; }
$options = array(); $filters = array(); $actions = array(); $db_delta_calls = 0; $scheduled = array(); $schedule_calls = array(); $schedule_row_counts = array(); $schedule_fail = false; $spawn_calls = 0;
function get_option( string $key, mixed $default = false ): mixed { global $options; return $options[ $key ] ?? $default; }
function update_option( string $key, mixed $value, mixed $autoload = null ): bool { global $options; $options[ $key ] = $value; return true; }
function dbDelta( string $sql ): void { global $db_delta_calls; ++$db_delta_calls; }
function add_action( string $hook, callable $callback, int $priority = 10, int $accepted = 1 ): void {}
function do_action( string $hook, mixed ...$args ): void { global $actions; $actions[] = array( $hook, $args ); }
function add_filter( string $hook, callable $callback, int $priority = 10, int $accepted = 1 ): void { global $filters; $filters[ $hook ][] = $callback; }
function apply_filters( string $hook, mixed $value, mixed ...$args ): mixed { global $filters; foreach ( $filters[ $hook ] ?? array() as $callback ) $value = $callback( $value, ...$args ); return $value; }
function wp_next_scheduled( string $hook, array $args = array() ): int|false { global $scheduled; foreach ( $scheduled as $event ) if ( $event['hook'] === $hook && $event['args'] === $args ) return $event['timestamp']; return false; }
function wp_schedule_single_event( int $timestamp, string $hook, array $args = array(), bool $wp_error = false ): bool|WP_Error { global $scheduled, $schedule_calls, $schedule_row_counts, $schedule_fail, $wpdb; $schedule_calls[] = array( $hook, $args ); $schedule_row_counts[] = count( $wpdb->rows ); if ( $schedule_fail ) return new WP_Error( 'schedule_failed' ); $scheduled[] = compact( 'timestamp', 'hook', 'args' ); return true; }
function spawn_cron( int $timestamp = 0 ): bool { global $spawn_calls; ++$spawn_calls; return true; }
class WP_REST_Request implements ArrayAccess {
	public function __construct( private array $params, private array $headers, private string $body ) {}
	public function get_header( string $name ): string { return $this->headers[ strtolower( $name ) ] ?? ''; }
	public function get_body(): string { return $this->body; }
	public function offsetExists( mixed $offset ): bool { return isset( $this->params[ $offset ] ); }
	public function offsetGet( mixed $offset ): mixed { return $this->params[ $offset ] ?? null; }
	public function offsetSet( mixed $offset, mixed $value ): void {} public function offsetUnset( mixed $offset ): void {}
}

class FakeDb {
	public string $prefix = 'wp_'; public int $insert_id = 0; public array $rows = array();
	public function prepare( string $query, ...$args ): string { return json_encode( array( $query, $args ) ); }
	private function args( string $prepared ): array { return json_decode( $prepared, true )[1]; }
	public function query( string $prepared ): int|false {
		[$sql, $a] = json_decode( $prepared, true );
		if ( str_starts_with( $sql, 'INSERT IGNORE' ) ) { foreach ( $this->rows as $r ) { if ( $r['source'] === $a[0] && $r['external_id'] === $a[1] ) return 0; } $this->insert_id = count( $this->rows ) + 1; $this->rows[] = array( 'id' => $this->insert_id, 'source' => $a[0], 'external_id' => $a[1], 'runtime_id' => $a[2], 'envelope' => $a[3], 'status' => 'queued', 'attempts' => 0, 'available_at' => $a[4], 'lease_token' => null, 'lease_expires_at' => null ); return 1; }
		if ( str_contains( $sql, 'SET runtime_id = %s' ) ) { foreach ( $this->rows as &$r ) if ( $r['id'] === (int) $a[1] && '' === $r['runtime_id'] ) { $r['runtime_id'] = $a[0]; return 1; } return 0; }
		if ( str_contains( $sql, "SET status = 'queued', lease_token = NULL, lease_expires_at = NULL, updated_at") && str_contains( $sql, "lease_expires_at <") ) { foreach ( $this->rows as &$r ) if ( $r['status'] === 'leased' && $r['lease_expires_at'] < $a[1] ) { $r['status'] = 'queued'; $r['lease_token'] = null; $r['lease_expires_at'] = null; } return 1; }
		if ( str_contains( $sql, "SET status = 'leased'" ) ) { preg_match( '/\["runtime_id = %s",\["([^"]+)"\]\]/', $sql, $owner ); foreach ( $this->rows as &$r ) if ( $r['id'] === (int) $a[3] && $r['status'] === 'queued' && ( empty( $owner[1] ) || $r['runtime_id'] === $owner[1] ) ) { $r['status'] = 'leased'; $r['lease_token'] = $a[0]; $r['lease_expires_at'] = $a[1]; ++$r['attempts']; return 1; } return 0; }
		if ( str_contains( $sql, "SET status = 'acked'" ) ) { foreach ( $this->rows as &$r ) if ( $r['id'] === (int) $a[1] && $r['status'] === 'leased' && $r['lease_token'] === $a[2] ) { $r['status'] = 'acked'; return 1; } return 0; }
		if ( str_contains( $sql, "SET status = 'queued', lease_token = NULL, lease_expires_at = NULL, available_at") ) { foreach ( $this->rows as &$r ) if ( $r['id'] === (int) $a[2] && $r['status'] === 'leased' && $r['lease_token'] === $a[3] ) { $r['status'] = 'queued'; $r['lease_token'] = null; return 1; } return 0; }
		return 0;
	}
	public function get_var( string $prepared ): mixed { [$sql, $a] = json_decode( $prepared, true ); if ( str_starts_with( $sql, 'SHOW TABLES LIKE' ) ) return $a[0]; foreach ( $this->rows as $r ) if ( $r['source'] === $a[0] && $r['external_id'] === $a[1] ) return $r['id']; return null; }
	public function get_row( string $prepared, mixed $format ): ?array { [$sql, $a] = json_decode( $prepared, true ); if ( str_contains( $sql, "WHERE") && str_contains( $sql, "status = 'queued'") ) { preg_match( '/\["runtime_id = %s",\["([^"]+)"\]\]/', $sql, $owner ); foreach ( $this->rows as $r ) if ( $r['status'] === 'queued' && '' !== $r['runtime_id'] && ( empty( $owner[1] ) || $r['runtime_id'] === $owner[1] ) ) return array( 'id' => $r['id'] ); } foreach ( $this->rows as $r ) if ( $r['id'] === (int) $a[0] && $r['lease_token'] === $a[1] ) return array( 'id' => $r['id'], 'envelope' => $r['envelope'] ); return null; }
	public function get_results( string $sql, mixed $format ): array { return array_values( array_filter( $this->rows, static fn( $row ) => '' === $row['runtime_id'] ) ); }
}
$wpdb = new FakeDb();
require __DIR__ . '/../templates/wp-coding-agents-inbound-events.php';
$failures = array(); $assert = static function( string $name, bool $ok ) use ( &$failures ): void { echo ($ok ? 'PASS' : 'FAIL') . ": $name\n"; if ( ! $ok ) $failures[] = $name; };
$event = array( 'source' => 'signed-source', 'external_id' => 'event-1', 'type' => 'message', 'conversation_id' => 'conversation-1', 'runtime_id' => 'runtime-opaque-1', 'message' => 'hello', 'attributes' => array() );
$normalized = WpCodingAgents_Inbound_Events::normalize( $event );
$assert( 'normalizes the minimal envelope', is_array( $normalized ) && $normalized === $event );
$with_auth = WpCodingAgents_Inbound_Events::normalize( $event + array( 'signature' => 'secret', 'authorization' => 'Bearer secret' ) );
$assert( 'normalization drops adapter authentication material', is_array( $with_auth ) && ! array_key_exists( 'signature', $with_auth ) && ! array_key_exists( 'authorization', $with_auth ) );
$attributes = WpCodingAgents_Inbound_Events::normalize( array_merge( $event, array( 'attributes' => array( 'provider_id' => 'verified', 'signature' => 'secret' ) ) ) );
$assert( 'attributes are bounded scalar strings and drop authentication material', is_array( $attributes ) && array( 'provider_id' => 'verified' ) === $attributes['attributes'] && is_wp_error( WpCodingAgents_Inbound_Events::normalize( array_merge( $event, array( 'attributes' => array( 'Bad-Key' => 'value' ) ) ) ) ) );
$assert( 'runtime ID is required and bounded', is_wp_error( WpCodingAgents_Inbound_Events::normalize( array_diff_key( $event, array( 'runtime_id' => true ) ) ) ) && is_wp_error( WpCodingAgents_Inbound_Events::normalize( array_merge( $event, array( 'runtime_id' => str_repeat( 'x', 192 ) ) ) ) ) );
$first = WpCodingAgents_Inbound_Events::enqueue( $event ); $second = WpCodingAgents_Inbound_Events::enqueue( $event );
$assert( 'durably deduplicates source and external ID', $first['new'] && ! $second['new'] && $first['id'] === $second['id'] );
$assert( 'queue record excludes adapter-only authentication material', ! str_contains( $wpdb->rows[0]['envelope'], 'signature' ) );
$claim = WpCodingAgents_Inbound_Events::claim();
$assert( 'claims an available event with a lease token', is_array( $claim ) && $claim['event'] === $event && '' !== $claim['lease_token'] );
$assert( 'second claimant cannot take an active lease', null === WpCodingAgents_Inbound_Events::claim() );
$assert( 'wrong lease token cannot acknowledge', ! WpCodingAgents_Inbound_Events::acknowledge( $claim['id'], 'wrong' ) );
$assert( 'lease owner can retry', WpCodingAgents_Inbound_Events::retry( $claim['id'], $claim['lease_token'] ) );
$retry = WpCodingAgents_Inbound_Events::claim();
$assert( 'retried event is claimable again', is_array( $retry ) && 2 === $wpdb->rows[0]['attempts'] );
$wpdb->rows[0]['lease_expires_at'] = '2000-01-01 00:00:00';
$recovered = WpCodingAgents_Inbound_Events::claim();
$assert( 'stale lease is recovered before a new claim', is_array( $recovered ) && 3 === $wpdb->rows[0]['attempts'] );
$assert( 'lease owner can acknowledge exactly once', WpCodingAgents_Inbound_Events::acknowledge( $recovered['id'], $recovered['lease_token'] ) && ! WpCodingAgents_Inbound_Events::acknowledge( $recovered['id'], $recovered['lease_token'] ) );
WpCodingAgents_Inbound_Events::install(); WpCodingAgents_Inbound_Events::install();
$assert( 'schema installation is version-gated', 1 === $db_delta_calls );

add_filter( 'wp_coding_agents_inbound_event_adapter_config', static function( array $config, string $adapter ): array { $config['slack'] = array( 'signing_secret' => 'test-signing-secret', 'runtime_id' => 'opaque-runtime-id', 'allowed_team_ids' => array( 'T123' ), 'allowed_channel_ids' => array( 'C123' ) ); return $config; } );
$payload = json_encode( array( 'type' => 'event_callback', 'team_id' => 'T123', 'event_id' => 'slack-event-1', 'event' => array( 'type' => 'message', 'user' => 'U123', 'channel' => 'C123', 'ts' => '1710000000.000001', 'text' => 'signed hello' ) ) );
$timestamp = (string) time(); $signature = 'v0=' . hash_hmac( 'sha256', 'v0:' . $timestamp . ':' . $payload, 'test-signing-secret' );
$request = new WP_REST_Request( array( 'adapter' => 'slack' ), array( 'x-slack-request-timestamp' => $timestamp, 'x-slack-signature' => $signature ), $payload );
$response = WpCodingAgents_Inbound_Events::ingress( $request );
$assert( 'signed Slack event is acknowledged after durable queue insertion', is_array( $response ) && true === $response['accepted'] && 2 === count( $wpdb->rows ) );
$assert( 'queue is durable before runtime wake scheduling', array( 2 ) === $schedule_row_counts && 1 === count( $schedule_calls ) );
$assert( 'ingress does not synchronously execute the runtime action', 1 === count( $actions ) && 'wp_coding_agents_inbound_event_queued' === $actions[0][0] && 1 === $spawn_calls );
$duplicate = WpCodingAgents_Inbound_Events::ingress( $request );
$assert( 'duplicate coalesces the pending runtime wake', is_array( $duplicate ) && true === $duplicate['duplicate'] && 1 === count( $schedule_calls ) && 1 === count( $actions ) );
$scheduled = array(); $schedule_fail = true;
$repair_payload = json_encode( array( 'type' => 'event_callback', 'team_id' => 'T123', 'event_id' => 'slack-event-repair', 'event' => array( 'type' => 'message', 'user' => 'U123', 'channel' => 'C123', 'ts' => '1710000001.000001', 'text' => 'repair wake' ) ) ); $repair_signature = 'v0=' . hash_hmac( 'sha256', 'v0:' . $timestamp . ':' . $repair_payload, 'test-signing-secret' ); $repair_request = new WP_REST_Request( array( 'adapter' => 'slack' ), array( 'x-slack-request-timestamp' => $timestamp, 'x-slack-signature' => $repair_signature ), $repair_payload );
$failed_wake = WpCodingAgents_Inbound_Events::ingress( $repair_request );
$assert( 'failed scheduling returns retryable error after durable queueing', is_wp_error( $failed_wake ) && 3 === count( $wpdb->rows ) && 2 === count( $schedule_calls ) );
$schedule_fail = false; $repaired_wake = WpCodingAgents_Inbound_Events::ingress( $repair_request );
$assert( 'duplicate repairs a missing pending runtime wake', is_array( $repaired_wake ) && true === $repaired_wake['duplicate'] && 3 === count( $schedule_calls ) && 1 === count( $scheduled ) );
WpCodingAgents_Inbound_Events::wake_runtime( 'opaque-runtime-id', 'inbound_event' );
$assert( 'runtime action executes only from the cron callback', 3 === count( $actions ) && 'wp_coding_agents_runtime_requested' === $actions[2][0] && array( 'opaque-runtime-id', 'inbound_event' ) === $actions[2][1] );
$assert( 'Slack queue envelope excludes request credentials and raw payload', ! str_contains( $wpdb->rows[1]['envelope'], 'test-signing-secret' ) && ! str_contains( $wpdb->rows[1]['envelope'], $signature ) && ! str_contains( $wpdb->rows[1]['envelope'], 'event_callback' ) );
$url_body = json_encode( array( 'type' => 'url_verification', 'challenge' => 'challenge-value' ) ); $url_signature = 'v0=' . hash_hmac( 'sha256', 'v0:' . $timestamp . ':' . $url_body, 'test-signing-secret' );
$url_response = WpCodingAgents_Inbound_Events::ingress( new WP_REST_Request( array( 'adapter' => 'slack' ), array( 'x-slack-request-timestamp' => $timestamp, 'x-slack-signature' => $url_signature ), $url_body ) );
$assert( 'Slack URL verification returns immediately without queueing', array( 'challenge' => 'challenge-value' ) === $url_response && 3 === count( $wpdb->rows ) );
$bad_signature = WpCodingAgents_Inbound_Events::ingress( new WP_REST_Request( array( 'adapter' => 'slack' ), array( 'x-slack-request-timestamp' => $timestamp, 'x-slack-signature' => 'v0=bad' ), $payload ) );
$assert( 'Slack rejects invalid signatures before queueing', is_wp_error( $bad_signature ) && 3 === count( $wpdb->rows ) );
$stale_timestamp = (string) ( time() - 301 ); $stale_signature = 'v0=' . hash_hmac( 'sha256', 'v0:' . $stale_timestamp . ':' . $payload, 'test-signing-secret' );
$stale = WpCodingAgents_Inbound_Events::ingress( new WP_REST_Request( array( 'adapter' => 'slack' ), array( 'x-slack-request-timestamp' => $stale_timestamp, 'x-slack-signature' => $stale_signature ), $payload ) );
$assert( 'Slack rejects stale timestamps before queueing', is_wp_error( $stale ) && 3 === count( $wpdb->rows ) );
$bot_payload = json_encode( array( 'type' => 'event_callback', 'team_id' => 'T123', 'event_id' => 'slack-event-bot', 'event' => array( 'type' => 'message', 'user' => 'U123', 'channel' => 'C123', 'ts' => '1710000002.000001', 'text' => 'ignore', 'bot_id' => 'B1' ) ) ); $bot_signature = 'v0=' . hash_hmac( 'sha256', 'v0:' . $timestamp . ':' . $bot_payload, 'test-signing-secret' );
$bot_response = WpCodingAgents_Inbound_Events::ingress( new WP_REST_Request( array( 'adapter' => 'slack' ), array( 'x-slack-request-timestamp' => $timestamp, 'x-slack-signature' => $bot_signature ), $bot_payload ) );
$assert( 'Slack bot events are acknowledged without queueing', is_array( $bot_response ) && true === $bot_response['accepted'] && 3 === count( $wpdb->rows ) );
$foreign_team_payload = json_encode( array( 'type' => 'event_callback', 'team_id' => 'T999', 'event_id' => 'slack-event-foreign', 'event' => array( 'type' => 'message', 'user' => 'U123', 'channel' => 'C123', 'ts' => '1710000004.000001', 'text' => 'ignore foreign team' ) ) ); $foreign_team_signature = 'v0=' . hash_hmac( 'sha256', 'v0:' . $timestamp . ':' . $foreign_team_payload, 'test-signing-secret' );
$foreign_team_response = WpCodingAgents_Inbound_Events::ingress( new WP_REST_Request( array( 'adapter' => 'slack' ), array( 'x-slack-request-timestamp' => $timestamp, 'x-slack-signature' => $foreign_team_signature ), $foreign_team_payload ) );
$assert( 'Slack events from a different team are acknowledged without queueing', is_array( $foreign_team_response ) && true === $foreign_team_response['accepted'] && 3 === count( $wpdb->rows ) );
$root = WpCodingAgents_Inbound_Events::slack( $request );
$reply_payload = json_encode( array( 'type' => 'event_callback', 'team_id' => 'T123', 'event_id' => 'slack-event-reply', 'event' => array( 'type' => 'app_mention', 'user' => 'W123', 'channel' => 'C123', 'ts' => '1710000003.000001', 'thread_ts' => '1710000000.000001', 'text' => 'thread reply' ) ) ); $reply_signature = 'v0=' . hash_hmac( 'sha256', 'v0:' . $timestamp . ':' . $reply_payload, 'test-signing-secret' );
$reply = WpCodingAgents_Inbound_Events::slack( new WP_REST_Request( array( 'adapter' => 'slack' ), array( 'x-slack-request-timestamp' => $timestamp, 'x-slack-signature' => $reply_signature ), $reply_payload ) );
$assert( 'Slack root and replies retain stable thread conversation identity', is_array( $root ) && is_array( $reply ) && 'C123:1710000000.000001' === $root['conversation_id'] && $root['conversation_id'] === $reply['conversation_id'] );
$assert( 'Slack preserves message and app mention event types', is_array( $root ) && is_array( $reply ) && 'message' === $root['type'] && 'app_mention' === $reply['type'] && 'W123' === $reply['attributes']['actor_id'] );
$assert( 'Slack envelope retains only reconstruction attributes', is_array( $root ) && array( 'team_id' => 'T123', 'channel_id' => 'C123', 'actor_id' => 'U123', 'message_ts' => '1710000000.000001', 'thread_ts' => '1710000000.000001' ) === $root['attributes'] );
$legacy = $event; $legacy['external_id'] = 'legacy-event'; $legacy['runtime_id'] = 'runtime-legacy'; $wpdb->rows[] = array( 'id' => 99, 'source' => $legacy['source'], 'external_id' => $legacy['external_id'], 'runtime_id' => '', 'envelope' => json_encode( $legacy ), 'status' => 'queued', 'attempts' => 0, 'available_at' => current_time( 'mysql', true ), 'lease_token' => null, 'lease_expires_at' => null ); $wpdb->rows[] = array( 'id' => 100, 'source' => 'legacy', 'external_id' => 'invalid-legacy', 'runtime_id' => '', 'envelope' => '{}', 'status' => 'queued', 'attempts' => 0, 'available_at' => current_time( 'mysql', true ), 'lease_token' => null, 'lease_expires_at' => null ); $options['wp_coding_agents_inbound_events_schema'] = 1; WpCodingAgents_Inbound_Events::install();
$assert( 'v1 migration backfills valid envelope owners and leaves invalid rows fail-closed', 2 <= $db_delta_calls && 'runtime-legacy' === $wpdb->rows[ count( $wpdb->rows ) - 2 ]['runtime_id'] && '' === $wpdb->rows[ count( $wpdb->rows ) - 1 ]['runtime_id'] );
$runtime_a = array_merge( $event, array( 'external_id' => 'runtime-a-event', 'runtime_id' => 'runtime-a' ) ); $runtime_b = array_merge( $event, array( 'external_id' => 'runtime-b-event', 'runtime_id' => 'runtime-b' ) ); WpCodingAgents_Inbound_Events::enqueue( $runtime_a ); WpCodingAgents_Inbound_Events::enqueue( $runtime_b ); $claimed_a = WpCodingAgents_Inbound_Events::claim( 'runtime-a' ); $claimed_b = WpCodingAgents_Inbound_Events::claim( 'runtime-b' );
$assert( 'runtime-filtered claims cannot cross-claim queued rows', is_array( $claimed_a ) && is_array( $claimed_b ) && 'runtime-a' === $claimed_a['event']['runtime_id'] && 'runtime-b' === $claimed_b['event']['runtime_id'] );
exit( $failures ? 1 : 0 );
