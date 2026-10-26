<?php
/**
 * Plugin Name: wp-coding-agents — site identity guard
 * Description: Refuses automated changes to the agent home site's identity.
 *              Managed by wp-coding-agents setup/upgrade — do not edit by hand.
 *
 * WHY THIS EXISTS
 *
 * This site is the assistant's home: memory, wiki, configuration and runtime
 * state live here. Test imports aimed at the nearest WordPress install can
 * replace its name, front page and theme, leaving the home site presenting as
 * somebody else's demo. Imports and smoke tests belong in a disposable site.
 *
 * CLI and REST changes fail loudly so a test cannot report success after
 * taking over the home site. Interactive wp-admin changes stay available;
 * operators can opt in explicitly for intentional automated changes.
 *
 * @package wp-coding-agents
 */

defined( 'ABSPATH' ) || exit;

/**
 * Refuse an automated identity change unless the operator opted in.
 *
 * @param mixed  $value     Proposed value.
 * @param mixed  $old_value Current value.
 * @param string $option    Option name.
 * @return mixed
 */
function wp_coding_agents_guard_site_identity_change( $value, $old_value, $option ) {
	$cli  = defined( 'WP_CLI' ) && WP_CLI;
	$rest = defined( 'REST_REQUEST' ) && REST_REQUEST;
	if ( ( ! $cli && ! $rest ) || $value === $old_value ) {
		return $value;
	}

	if ( getenv( 'WP_CODING_AGENTS_ALLOW_SITE_IDENTITY_CHANGE' ) ||
		( defined( 'WP_CODING_AGENTS_ALLOW_SITE_IDENTITY_CHANGE' ) && WP_CODING_AGENTS_ALLOW_SITE_IDENTITY_CHANGE ) ) {
		return $value;
	}

	$message = sprintf(
		'This is the agent home site. Changing option "%s" requires explicit opt-in: WP_CODING_AGENTS_ALLOW_SITE_IDENTITY_CHANGE=1. Run imports and tests in a disposable site.',
		$option
	);
	if ( $cli ) {
		WP_CLI::error( $message );
	}

	wp_die(
		new WP_Error( 'wp_coding_agents_site_identity_guard', $message, array( 'status' => 403 ) ),
		'',
		array( 'response' => 403 )
	);
}

/** Register after plugins load so site plugins can filter the guarded list. */
function wp_coding_agents_register_site_identity_guard(): void {
	$guarded = array( 'stylesheet', 'template', 'show_on_front', 'page_on_front', 'page_for_posts', 'blogname' );

	/**
	 * Filters the options protected from automated identity changes.
	 *
	 * @param string[] $guarded Option names.
	 */
	$filtered = apply_filters( 'wp_coding_agents_site_identity_guarded_options', $guarded );
	$guarded  = is_array( $filtered ) ? array_values( array_filter( array_map( 'strval', $filtered ) ) ) : $guarded;
	foreach ( $guarded as $option ) {
		add_filter( 'pre_update_option_' . $option, 'wp_coding_agents_guard_site_identity_change', 100, 3 );
	}
}
add_action( 'plugins_loaded', 'wp_coding_agents_register_site_identity_guard' );
