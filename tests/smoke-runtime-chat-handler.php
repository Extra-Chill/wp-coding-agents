<?php
/**
 * Runtime-backed agents/chat handler smoke test (#770).
 *
 * Asserts the deliverable contract: a configured agent's chat turn enqueues
 * exactly one durable inbound event and returns a pending run, an unconfigured
 * agent is untouched, the WP-session-to-runtime-conversation mapping persists
 * and fails closed when missing, and claim/ack scoping by runtime_id holds.
 */
declare( strict_types=1 );

namespace AgentsAPI\AI\Channels {
	function agents_chat_permission( array $input ): bool { return (bool) $GLOBALS['chat_permission']; }
}

namespace {
define( 'ABSPATH', __DIR__ . '/' );
define( 'ARRAY_A', 'ARRAY_A' );
class WP_Error { public function __construct( public string $code = '', public string $message = '', public mixed $data = null ) {} public function get_error_code(): string { return $this->code; } }
function is_wp_error( mixed $value ): bool { return $value instanceof WP_Error; }
function wp_json_encode( mixed $value ): string|false { return json_encode( $value ); }
function current_time( string $type, bool $gmt = false ): string { return gmdate( 'Y-m-d H:i:s' ); }
function wp_generate_uuid4(): string { static $n = 0; return 'uuid-' . ++$n; }
function rest_ensure_response( mixed $value ): mixed { return $value; }
$options = array(); $filters = array(); $actions = array(); $scheduled = array(); $current_user_id = 7; $chat_permission = true;
function get_option( string $key, mixed $default = false ): mixed { global $options; return $options[ $key ] ?? $default; }
function update_option( string $key, mixed $value, mixed $autoload = null ): bool { global $options; $options[ $key ] = $value; return true; }
function dbDelta( string $sql ): void {}
function get_current_user_id(): int { global $current_user_id; return $current_user_id; }
function add_action( string $hook, callable $callback, int $priority = 10, int $accepted = 1 ): void {}
function do_action( string $hook, mixed ...$args ): void { global $actions; $actions[] = array( $hook, $args ); }
function add_filter( string $hook, callable $callback, int $priority = 10, int $accepted = 1 ): void { global $filters; $filters[ $hook ][] = $callback; }
function apply_filters( string $hook, mixed $value, mixed ...$args ): mixed { global $filters; foreach ( $filters[ $hook ] ?? array() as $callback ) $value = $callback( $value, ...$args ); return $value; }
function wp_next_scheduled( string $hook, array $args = array() ): int|false { global $scheduled; foreach ( $scheduled as $event ) if ( $event['hook'] === $hook && $event['args'] === $args ) return $event['timestamp']; return false; }
function wp_schedule_single_event( int $timestamp, string $hook, array $args = array(), bool $wp_error = false ): bool { global $scheduled; $scheduled[] = compact( 'timestamp', 'hook', 'args' ); return true; }
function spawn_cron( int $timestamp = 0 ): bool { return true; }

class FakeDb {
	public string $prefix = 'wp_'; public int $insert_id = 0; public array $rows = array(); public array $maps = array();
	public function prepare( string $query, ...$args ): string { return json_encode( array( $query, $args ) ); }
	public function query( string $prepared ): int|false {
		[$sql, $a] = json_decode( $prepared, true );
		if ( str_contains( $sql, 'wp_coding_agents_runtime_conversations' ) && str_starts_with( $sql, 'INSERT IGNORE' ) ) { foreach ( $this->maps as $m ) { if ( $m['session_id'] === $a[0] ) return 0; } $this->maps[] = array( 'id' => count( $this->maps ) + 1, 'session_id' => $a[0], 'runtime_id' => $a[1], 'runtime_conversation_id' => $a[2], 'created_at' => $a[3], 'updated_at' => $a[4] ); return 1; }
		if ( str_starts_with( $sql, 'INSERT IGNORE' ) ) { foreach ( $this->rows as $r ) { if ( $r['source'] === $a[0] && $r['external_id'] === $a[1] ) return 0; } $this->insert_id = count( $this->rows ) + 1; $this->rows[] = array( 'id' => $this->insert_id, 'source' => $a[0], 'external_id' => $a[1], 'runtime_id' => $a[2], 'envelope' => $a[3], 'status' => 'queued', 'attempts' => 0, 'available_at' => $a[4], 'lease_token' => null, 'lease_expires_at' => null ); return 1; }
		if ( str_contains( $sql, "SET status = 'queued', lease_token = NULL, lease_expires_at = NULL, updated_at") && str_contains( $sql, "lease_expires_at <") ) { foreach ( $this->rows as &$r ) if ( $r['status'] === 'leased' && $r['lease_expires_at'] < $a[1] ) { $r['status'] = 'queued'; $r['lease_token'] = null; $r['lease_expires_at'] = null; } return 1; }
		if ( str_contains( $sql, "SET status = 'leased'" ) ) { preg_match( '/\["runtime_id = %s",\["([^"]+)"\]\]/', $sql, $owner ); foreach ( $this->rows as &$r ) if ( $r['id'] === (int) $a[3] && $r['status'] === 'queued' && ( empty( $owner[1] ) || $r['runtime_id'] === $owner[1] ) ) { $r['status'] = 'leased'; $r['lease_token'] = $a[0]; $r['lease_expires_at'] = $a[1]; ++$r['attempts']; return 1; } return 0; }
		if ( str_contains( $sql, "SET status = 'acked'" ) ) { foreach ( $this->rows as &$r ) if ( $r['id'] === (int) $a[1] && $r['status'] === 'leased' && $r['lease_token'] === $a[2] ) { $r['status'] = 'acked'; return 1; } return 0; }
		if ( str_contains( $sql, "SET status = 'queued', lease_token = NULL, lease_expires_at = NULL, available_at") ) { foreach ( $this->rows as &$r ) if ( $r['id'] === (int) $a[2] && $r['status'] === 'leased' && $r['lease_token'] === $a[3] ) { $r['status'] = 'queued'; $r['lease_token'] = null; return 1; } return 0; }
		return 0;
	}
	public function get_var( string $prepared ): mixed { [$sql, $a] = json_decode( $prepared, true ); if ( str_starts_with( $sql, 'SHOW TABLES LIKE' ) ) return $a[0]; foreach ( $this->rows as $r ) if ( $r['source'] === $a[0] && $r['external_id'] === $a[1] ) return $r['id']; return null; }
	public function get_row( string $prepared, mixed $format ): ?array {
		[$sql, $a] = json_decode( $prepared, true );
		if ( str_contains( $sql, 'wp_coding_agents_runtime_conversations' ) ) { foreach ( $this->maps as $m ) if ( $m['session_id'] === $a[0] ) return array( 'runtime_id' => $m['runtime_id'], 'runtime_conversation_id' => $m['runtime_conversation_id'] ); return null; }
		if ( str_contains( $sql, "status = 'queued'") ) { preg_match( '/\["runtime_id = %s",\["([^"]+)"\]\]/', $sql, $owner ); foreach ( $this->rows as $r ) if ( $r['status'] === 'queued' && '' !== $r['runtime_id'] && ( empty( $owner[1] ) || $r['runtime_id'] === $owner[1] ) ) return array( 'id' => $r['id'] ); return null; }
		foreach ( $this->rows as $r ) if ( $r['id'] === (int) $a[0] && $r['lease_token'] === $a[1] ) return array( 'id' => $r['id'], 'envelope' => $r['envelope'] );
		return null;
	}
	public function get_results( string $sql, mixed $format ): array { return array(); }
}
$wpdb = new FakeDb();
require __DIR__ . '/../templates/wp-coding-agents-inbound-events.php';
$failures = array(); $assert = static function( string $name, bool $ok ) use ( &$failures ): void { echo ($ok ? 'PASS' : 'FAIL') . ": $name\n"; if ( ! $ok ) $failures[] = $name; };

// Installer-written config: one agent slug mapped to one opaque runtime ID.
add_filter( 'wp_coding_agents_inbound_event_adapter_config', static function( array $config, string $adapter ): array {
	$config['runtime-chat'] = array( 'agents' => array( 'site-agent' => 'runtime-chat-1' ) );
	return $config;
}, 10, 2 );

$turn = array( 'agent' => 'site-agent', 'message' => 'deploy the fix', 'run_id' => 'run_0001', 'session_id' => null, 'attachments' => array( array( 'type' => 'image', 'url' => 'https://example.com/a.png' ) ) );

$assert( 'an unconfigured agent is untouched', null === apply_filters( 'wp_agent_chat_handler', null, array( 'agent' => 'other-agent', 'message' => 'hi' ) ) );
$existing = static function (): void {};
$assert( 'an earlier registered handler is respected', $existing === apply_filters( 'wp_agent_chat_handler', $existing, $turn ) );
$handler = apply_filters( 'wp_agent_chat_handler', null, $turn );
$assert( 'a configured agent gets the runtime chat handler', is_callable( $handler ) );

$result = call_user_func( $handler, $turn );
$assert( 'a configured turn enqueues exactly one event', is_array( $result ) && 1 === count( $wpdb->rows ) );
$assert( 'the turn returns a pending run', is_array( $result ) && false === $result['completed'] && '' === $result['reply'] && is_string( $result['session_id'] ) && '' !== $result['session_id'] && true === $result['metadata']['wp_coding_agents']['pending'] && false === $result['metadata']['wp_coding_agents']['duplicate'] );
$session_id = is_array( $result ) ? $result['session_id'] : '';
$envelope = json_decode( $wpdb->rows[0]['envelope'] ?? '', true );
$assert( 'the event carries conversation_id = WP session_id, the message, the acting user, and the run_id', is_array( $envelope ) && 'agents-chat' === $envelope['source'] && 'chat_message' === $envelope['type'] && $session_id === $envelope['conversation_id'] && 'runtime-chat-1' === $envelope['runtime_id'] && 'deploy the fix' === $envelope['message'] && 'run_0001' === $envelope['attributes']['run_id'] && '7' === $envelope['attributes']['actor_user_id'] && 'site-agent' === $envelope['attributes']['agent'] );
$assert( 'the event carries the attachments', is_array( $envelope ) && array( array( 'type' => 'image', 'url' => 'https://example.com/a.png' ) ) === $envelope['attachments'] );
$assert( 'the runtime wake was scheduled for the configured runtime', false !== wp_next_scheduled( 'wp_coding_agents_runtime_wake', array( 'runtime-chat-1', 'inbound_event' ) ) );

$assert( 'the first turn persisted the durable session-to-runtime-conversation mapping', 1 === count( $wpdb->maps ) && $session_id === $wpdb->maps[0]['session_id'] && 'runtime-chat-1' === $wpdb->maps[0]['runtime_id'] && $wpdb->maps[0]['runtime_conversation_id'] === $envelope['attributes']['runtime_conversation_id'] );

$replay = call_user_func( $handler, array_merge( $turn, array( 'session_id' => $session_id ) ) );
$assert( 'a replayed run_id stays a single durable event', is_array( $replay ) && 1 === count( $wpdb->rows ) && true === $replay['metadata']['wp_coding_agents']['duplicate'] );

$second = call_user_func( $handler, array( 'agent' => 'site-agent', 'message' => 'and run the tests', 'run_id' => 'run_0002', 'session_id' => $session_id ) );
$second_envelope = json_decode( $wpdb->rows[1]['envelope'] ?? '', true );
$assert( 'a continuing turn reuses the persisted mapping', is_array( $second ) && 2 === count( $wpdb->rows ) && 1 === count( $wpdb->maps ) && $session_id === $second['session_id'] && is_array( $second_envelope ) && $wpdb->maps[0]['runtime_conversation_id'] === $second_envelope['attributes']['runtime_conversation_id'] && ! isset( $second_envelope['attachments'] ) );

$unmapped = call_user_func( $handler, array( 'agent' => 'site-agent', 'message' => 'hello', 'run_id' => 'run_0003', 'session_id' => 'session-with-no-mapping' ) );
$assert( 'a continuing session without a mapping fails closed', is_wp_error( $unmapped ) && 'wp_coding_agents_runtime_chat_unmapped' === $unmapped->get_error_code() && 2 === count( $wpdb->rows ) );

$wpdb->maps[] = array( 'id' => 98, 'session_id' => 'session-owned-elsewhere', 'runtime_id' => 'runtime-foreign', 'runtime_conversation_id' => 'rc-foreign', 'created_at' => current_time( 'mysql', true ), 'updated_at' => current_time( 'mysql', true ) );
$foreign = call_user_func( $handler, array( 'agent' => 'site-agent', 'message' => 'hello', 'run_id' => 'run_0004', 'session_id' => 'session-owned-elsewhere' ) );
$assert( 'a session mapped to a different runtime fails closed', is_wp_error( $foreign ) && 'wp_coding_agents_runtime_chat_unmapped' === $foreign->get_error_code() && 2 === count( $wpdb->rows ) );

$current_user_id = 0;
$anonymous = call_user_func( $handler, array_merge( $turn, array( 'run_id' => 'run_0005' ) ) );
$assert( 'an anonymous caller fails closed without queueing', is_wp_error( $anonymous ) && 'wp_coding_agents_runtime_chat_forbidden' === $anonymous->get_error_code() && 2 === count( $wpdb->rows ) );
$current_user_id = 7; $chat_permission = false;
$denied = call_user_func( $handler, array_merge( $turn, array( 'run_id' => 'run_0006' ) ) );
$assert( 'the agents-api permission gate is re-validated as the authenticated user', is_wp_error( $denied ) && 'wp_coding_agents_runtime_chat_forbidden' === $denied->get_error_code() && 2 === count( $wpdb->rows ) );
$chat_permission = true;
$missing_run = call_user_func( $handler, array( 'agent' => 'site-agent', 'message' => 'hello' ) );
$assert( 'a turn without a dispatcher-assigned run_id fails closed', is_wp_error( $missing_run ) && 2 === count( $wpdb->rows ) );

// Cancellation flows through the same queue, scoped to durably mapped sessions.
$assert( 'cancellation of an unmapped session is untouched', null === apply_filters( 'wp_agent_chat_run_cancel_handler', null, array( 'run_id' => 'run_0001', 'session_id' => 'session-with-no-mapping' ) ) && null === apply_filters( 'wp_agent_chat_run_cancel_handler', null, array( 'run_id' => 'run_0004', 'session_id' => 'session-owned-elsewhere' ) ) );
$cancel_handler = apply_filters( 'wp_agent_chat_run_cancel_handler', null, array( 'run_id' => 'run_0001', 'session_id' => $session_id ) );
$assert( 'cancellation of a mapped session gets the runtime cancel handler', is_callable( $cancel_handler ) );
$cancelled = call_user_func( $cancel_handler, array( 'run_id' => 'run_0001', 'session_id' => $session_id ) );
$cancel_envelope = json_decode( $wpdb->rows[2]['envelope'] ?? '', true );
$assert( 'cancellation enqueues a chat_cancel event on the same conversation and returns cancelling', is_array( $cancelled ) && 'cancelling' === $cancelled['status'] && 3 === count( $wpdb->rows ) && is_array( $cancel_envelope ) && 'chat_cancel' === $cancel_envelope['type'] && $session_id === $cancel_envelope['conversation_id'] && 'runtime-chat-1' === $cancel_envelope['runtime_id'] && 'run_0001' === $cancel_envelope['attributes']['run_id'] );

// Claim/ack scoping by runtime_id holds for chat-origin events.
$assert( 'another runtime cannot claim the chat events', null === WpCodingAgents_Inbound_Events::claim( 'runtime-foreign' ) );
$claim = WpCodingAgents_Inbound_Events::claim( 'runtime-chat-1' );
$assert( 'the configured runtime claims the chat turn with its attachments', is_array( $claim ) && 'runtime-chat-1' === $claim['event']['runtime_id'] && 'chat_message' === $claim['event']['type'] && array( array( 'type' => 'image', 'url' => 'https://example.com/a.png' ) ) === $claim['event']['attachments'] );
$assert( 'a foreign lease token cannot acknowledge the claimed chat turn', ! WpCodingAgents_Inbound_Events::acknowledge( $claim['id'], 'wrong-token' ) );
$assert( 'the lease owner acknowledges after the runtime accepts the turn', WpCodingAgents_Inbound_Events::acknowledge( $claim['id'], $claim['lease_token'] ) );

exit( $failures ? 1 : 0 );
}
