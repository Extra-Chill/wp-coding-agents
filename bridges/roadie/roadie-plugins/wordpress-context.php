<?php
/** Host-owned memory resolver, evaluated inside WordPress by the Roadie plugin. */

$request = json_decode( base64_decode( $args[0] ?? '', true ), true );
if ( ! is_array( $request ) || ! in_array( $request['operation'] ?? '', array( 'person', 'context' ), true ) ) {
    throw new RuntimeException( 'Invalid Roadie context request.' );
}
$user_id = (int) ( $request['user_id'] ?? 0 );
$agent_slug = (string) ( $request['agent_slug'] ?? '' );
$agent = function_exists( 'wp_get_agent' ) ? wp_get_agent( $agent_slug ) : null;
if ( ! $agent instanceof WP_Agent ) {
    throw new RuntimeException( 'Roadie context agent is not registered.' );
}
$meta = $agent->get_meta();
$agent_id = (int) ( $meta['datamachine_agent_id'] ?? 0 );
if ( $agent_id <= 0 ) {
    throw new RuntimeException( 'Roadie context requires a persisted agent.' );
}
// Resolve an explicitly mapped user. Never promote the bridge process's WP
// account or a conversation owner into the current speaker.
$user = $user_id > 0 ? get_user_by( 'id', $user_id ) : false;
$identity_class = '\DataMachine\Core\Agents\AgentIdentityResolver';
$owner_id = class_exists( $identity_class ) ? ( new $identity_class() )->resolve_agent_identity( $agent_slug )->owner_id : 0;
$access_class = '\DataMachine\Core\Database\Agents\AgentAccess';
$granted = $user && class_exists( $access_class ) && ( new $access_class() )->user_can_access( $agent_id, $user_id, 'viewer' );
$allowed = $user && ( $user_id === $owner_id || user_can( $user, 'manage_options' ) || $granted );
$allowed = (bool) apply_filters( 'datamachine_can_access_agent', $allowed, $agent_id, $user_id, 'viewer' );
if ( 'person' === $request['operation'] ) {
    echo wp_json_encode( array( 'allowed' => $allowed && (bool) $user ) );
    return;
}
if ( 'turn' === ( $request['event'] ?? '' ) && ( ! $user || ! $allowed ) ) {
    echo wp_json_encode( array( 'sections' => array() ) );
    return;
}
$registry = '\DataMachine\Engine\AI\MemoryFileRegistry';
$memory_class = '\DataMachine\Core\FilesRepository\AgentMemory';
if ( ! class_exists( $registry ) || ! class_exists( $memory_class ) ) {
    throw new RuntimeException( 'WordPress memory registry is unavailable.' );
}
$files = $registry::get_for_modes( array( $registry::MODE_ALL ), array( $registry::INJECTION_AGENT_IDENTITY, $registry::INJECTION_AGENT_MEMORY, $registry::INJECTION_USER_PROFILE ) );
uasort( $files, static fn( $a, $b ) => (int) ( $a['priority'] ?? 50 ) <=> (int) ( $b['priority'] ?? 50 ) );
$sections = 'turn' === ( $request['event'] ?? '' ) ? array( array( 'id' => 'wordpress-current-user', 'content' => 'Current speaker context belongs to WordPress user ' . $user_id . '. Earlier speaker context is conversation history, not the current principal.' ) ) : array();
$total = 0;
foreach ( $files as $filename => $file ) {
    $layer = $file['layer'] ?? $registry::LAYER_AGENT;
    $personal = in_array( $layer, array( $registry::LAYER_USER, $registry::LAYER_PRINCIPAL ), true );
    if ( ( 'turn' === ( $request['event'] ?? '' ) ) !== $personal ) {
        continue;
    }
    // Explicit layers avoid owner fallback in the registry/store resolver.
    $memory = new $memory_class( $personal ? $user_id : 0, $agent_id, $filename, $layer );
    $read = $memory->get_all();
    if ( empty( $read['success'] ) || ! is_string( $read['content'] ?? null ) || '' === trim( $read['content'] ) ) {
        continue;
    }
    $content = substr( $read['content'], 0, 65536 );
    $total += strlen( $content );
    if ( $total > 131072 || count( $sections ) >= 50 ) {
        break;
    }
    $sections[] = array( 'id' => 'wordpress-' . $layer . '-' . $filename, 'title' => $filename, 'content' => $content );
}
echo wp_json_encode( array( 'sections' => $sections ) );
