<?php
/**
 * Read a Data Machine agent relationship as a runtime-neutral projection graph.
 *
 * Invoked through `wp eval-file ... -- <coordinator-slug>` or embedded in
 * `wp eval` after `$args` is initialized. The Agents API registry is therefore
 * loaded before this code reads its `subagents` edges.
 */

if ( ! function_exists( 'wp_get_agent' ) || ! function_exists( 'wp_get_ability' ) ) {
	throw new RuntimeException( 'The Agents API and Data Machine abilities must be loaded.' );
}

$coordinator_slug = isset( $args[0] ) ? sanitize_title( (string) $args[0] ) : '';
$embedded         = isset( $args[1] ) && 'embedded' === $args[1];
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
	if ( count( $visited ) > 64 || count( $memory['files'] ) > 256 ) {
		throw new RuntimeException( 'The portable agent graph exceeds its projection limit.' );
	}

	$instructions = array();
	$agent_root   = null;
	if ( $embedded ) {
		$directory_manager_class = '\DataMachine\Core\FilesRepository\DirectoryManager';
		if ( ! class_exists( $directory_manager_class ) ) {
			throw new RuntimeException( 'The Data Machine agent directory resolver is unavailable.' );
		}
		$directory_manager = new $directory_manager_class();
		$agent_root        = $directory_manager->resolve_agent_directory( array( 'agent_id' => $agent_id ) );
		if ( ! is_string( $agent_root ) || false === realpath( $agent_root ) || realpath( $agent_root ) !== $agent_root ) {
			throw new RuntimeException( sprintf( 'Agent "%s" has an invalid Data Machine identity root.', $slug ) );
		}
	}
	foreach ( $memory['files'] as $file ) {
		if ( ! is_array( $file ) || ! is_string( $file['filename'] ?? null ) || ! is_string( $file['path'] ?? null ) ) {
			continue;
		}
		if ( $embedded && 'agent' === ( $file['layer'] ?? null ) ) {
			opencode_subagent_assert_contained_file( $file['path'], $agent_root );
		}
		$instructions[ $file['filename'] ] = $embedded ? opencode_subagent_embedded_file( $file['path'] ) : $file['path'];
	}

	// Skills and references are explicit portable agent config declarations.
	// Each map key is the relative path retained by the runtime projection.
	$skills     = is_array( $config['skills'] ?? null ) ? $config['skills'] : array();
	$references = is_array( $config['references'] ?? null ) ? $config['references'] : array();
	if ( $embedded ) {
		if ( count( $skills ) + count( $references ) > 256 ) {
			throw new RuntimeException( 'The portable agent graph exceeds its projection limit.' );
		}
		$skills     = opencode_subagent_embedded_declared_files( $skills, $agent_root, 'skills' );
		$references = opencode_subagent_embedded_declared_files( $references, $agent_root, 'references' );
	}
	$subagents  = $agent->get_subagents();
	if ( count( $subagents ) > 64 ) {
		throw new RuntimeException( 'The portable agent graph exceeds its projection limit.' );
	}
	foreach ( $subagents as $child ) {
		$pending[] = $child;
	}

	$description = trim( $agent->get_description() );
	if ( '' === $description ) {
		$description = $agent->get_label();
	}

	$nodes[] = array(
		'slug'         => $slug,
		'description'  => $description,
		'model'        => is_string( $config['default_model'] ?? null ) ? $config['default_model'] : '',
		'subagents'    => $subagents,
		'sources'      => array(
			'instructions' => (object) $instructions,
			'skills'       => (object) $skills,
			'references'   => (object) $references,
		),
		'tool_policy'  => (object) ( is_array( $config['tool_policy'] ?? null ) ? $config['tool_policy'] : array() ),
		'skill_policy' => array( 'paths' => array_keys( $skills ) ),
	);
}

echo wp_json_encode(
	array_filter( array(
		'success'     => true,
		'coordinator' => $coordinator_slug,
		'nodes'       => $nodes,
		'source_mode' => $embedded ? 'embedded' : null,
	) ),
	JSON_UNESCAPED_SLASHES
);

/** Embed declared portable artifacts only from their owning Data Machine agent root. */
function opencode_subagent_embedded_declared_files( $files, $agent_root, $kind ) {
	$embedded = array();
	foreach ( $files as $target => $path ) {
		$parts = is_string( $target ) ? explode( '/', $target ) : array();
		if ( empty( $parts ) || in_array( '.', $parts, true ) || in_array( '..', $parts, true ) || ! preg_match( '#^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$#', $target ) ) {
			throw new RuntimeException( 'A declared portable agent artifact has an invalid relative path.' );
		}
		$expected = "{$agent_root}/{$kind}/{$target}";
		if ( $path !== $expected ) {
			throw new RuntimeException( 'A declared portable agent artifact is outside its agent root.' );
		}
		opencode_subagent_assert_contained_file( $path, $agent_root );
		$embedded[ $target ] = opencode_subagent_embedded_file( $path );
	}
	return $embedded;
}

/** Require a regular canonical file below a canonical Data Machine agent root. */
function opencode_subagent_assert_contained_file( $path, $agent_root ) {
	$real_path = is_string( $path ) ? realpath( $path ) : false;
	if ( false === $real_path || $real_path !== $path || 0 !== strpos( $path, trailingslashit( $agent_root ) ) || ! is_file( $path ) ) {
		throw new RuntimeException( 'A declared portable agent artifact is outside its agent root.' );
	}
}

/** Return bounded, binary-safe source content without retaining the remote path. */
function opencode_subagent_embedded_file( $path ) {
	static $total_bytes = 0;
	static $file_count  = 0;
	$max_file_bytes     = 2 * 1024 * 1024;
	$max_total_bytes    = 16 * 1024 * 1024;
	if ( ! is_string( $path ) || '' === $path || ! is_file( $path ) || ! is_readable( $path ) ) {
		throw new RuntimeException( 'Could not read a declared portable agent artifact.' );
	}
	$real_path = realpath( $path );
	if ( false === $real_path || $real_path !== $path ) {
		throw new RuntimeException( 'A declared portable agent artifact is outside its agent root.' );
	}
	$size = filesize( $path );
	if ( false === $size || $file_count >= 512 || $size > $max_file_bytes || $total_bytes + $size > $max_total_bytes ) {
		throw new RuntimeException( 'Declared portable agent artifacts exceed the projection size limit.' );
	}
	$content = file_get_contents( $path );
	if ( false === $content || strlen( $content ) !== $size ) {
		throw new RuntimeException( 'Could not read a declared portable agent artifact.' );
	}
	$total_bytes += $size;
	++$file_count;
	return base64_encode( $content );
}
