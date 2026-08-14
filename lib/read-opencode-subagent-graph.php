<?php
/**
 * Read a Data Machine agent relationship as a runtime-neutral projection graph.
 *
 * Invoked through `wp eval-file ... -- <coordinator-slug>` so the Agents API
 * registry is fully initialized before this code reads its `subagents` edges.
 */

if ( ! function_exists( 'wp_get_agent' ) || ! function_exists( 'wp_get_ability' ) ) {
	throw new RuntimeException( 'The Agents API and Data Machine abilities must be loaded.' );
}

$coordinator_slug = isset( $args[0] ) ? sanitize_title( (string) $args[0] ) : '';
$coordinator      = '' === $coordinator_slug ? null : wp_get_agent( $coordinator_slug );
if ( ! $coordinator instanceof WP_Agent ) {
	throw new RuntimeException( 'The coordinator is not a registered Agents API agent.' );
}

$agents   = wp_get_agents();
$pending  = array( $coordinator_slug );
$visited  = array();
$nodes    = array();
$ability  = wp_get_ability( 'datamachine/list-injectable-memory-files' );

while ( ! empty( $pending ) ) {
	$slug = array_shift( $pending );
	if ( isset( $visited[ $slug ] ) ) {
		continue;
	}
	$visited[ $slug ] = true;
	$agent            = $agents[ $slug ] ?? null;
	if ( ! $agent instanceof WP_Agent ) {
		throw new RuntimeException( sprintf( 'Registered agent "%s" declares an unresolved subagent.', $slug ) );
	}

	$config = $agent->get_default_config();
	$meta   = $agent->get_meta();
	$agent_id = (int) ( $meta['datamachine_agent_id'] ?? 0 );
	if ( $agent_id <= 0 || ! $ability ) {
		throw new RuntimeException( sprintf( 'Agent "%s" is not a persisted Data Machine agent.', $slug ) );
	}
	$memory = $ability->execute( array( 'agent_id' => $agent_id ) );
	if ( empty( $memory['success'] ) || ! is_array( $memory['files'] ?? null ) ) {
		throw new RuntimeException( sprintf( 'Could not resolve Data Machine identity files for "%s".', $slug ) );
	}

	$instructions = array();
	foreach ( $memory['files'] as $file ) {
		if ( ! is_array( $file ) || ! is_string( $file['filename'] ?? null ) || ! is_string( $file['path'] ?? null ) ) {
			continue;
		}
		$instructions[ $file['filename'] ] = $file['path'];
	}

	// Skills and references are explicit portable agent config declarations.
	// Each map key is the relative path retained by the runtime projection.
	$skills     = is_array( $config['skills'] ?? null ) ? $config['skills'] : array();
	$references = is_array( $config['references'] ?? null ) ? $config['references'] : array();
	$subagents  = $agent->get_subagents();
	foreach ( $subagents as $child ) {
		$pending[] = $child;
	}

	$nodes[] = array(
		'slug'         => $slug,
		'description'  => $agent->get_description(),
		'model'        => is_string( $config['default_model'] ?? null ) ? $config['default_model'] : '',
		'subagents'    => $subagents,
		'sources'      => array(
			'instructions' => $instructions,
			'skills'       => $skills,
			'references'   => $references,
		),
		'tool_policy'  => is_array( $config['tool_policy'] ?? null ) ? $config['tool_policy'] : array(),
		'skill_policy' => array( 'paths' => array_keys( $skills ) ),
	);
}

echo wp_json_encode(
	array(
		'success'     => true,
		'coordinator' => $coordinator_slug,
		'nodes'       => $nodes,
	),
	JSON_UNESCAPED_SLASHES
);
