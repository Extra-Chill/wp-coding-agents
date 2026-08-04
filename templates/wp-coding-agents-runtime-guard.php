<?php
/**
 * Plugin Name: wp-coding-agents — runtime deactivation guard
 * Description: Prevents the agent runtime from being deactivated or deleted
 *              through the wp-admin plugins screen on managed installs.
 *              Managed by wp-coding-agents setup/upgrade — do not edit by hand.
 *
 * WHY THIS EXISTS
 *
 * On a managed install the site owner has wp-admin access and no reason to
 * understand the plugins list. Deactivating Data Machine there costs them their
 * assistant's memory and tools, with no obvious way back for a non-technical
 * user.
 *
 * WHY NOT AN MU-PLUGIN MOVE
 *
 * Relocating the runtime into mu-plugins would also prevent deactivation, but
 * WordPress fatal-error recovery PAUSES a plugin that fatals and cannot do that
 * for an mu-plugin. Making the runtime unkillable would also make it
 * unpausable, turning a broken assistant into a white screen on a live site.
 * See Extra-Chill/wp-coding-agents#328 and #323.
 *
 * WP-CLI IS DELIBERATELY NOT GUARDED
 *
 * `wp plugin deactivate data-machine` stays available. That is the operator's
 * recovery path and was used during the managed-posture rollout. This guard
 * targets the admin UI, which is where the accident happens, not the CLI, which
 * is where recovery happens.
 *
 * @package wp-coding-agents
 */

defined( 'ABSPATH' ) || exit;

/**
 * Plugin basenames this install protects.
 *
 * Written by wp-coding-agents at setup/upgrade time between the markers below.
 *
 * @return string[]
 */
function wp_coding_agents_guarded_runtime_plugins(): array {
	$guarded = array(
		// BEGIN wp-coding-agents-guarded-plugins
		// END wp-coding-agents-guarded-plugins
	);

	/**
	 * Filters the plugins protected from admin-UI deactivation.
	 *
	 * @param string[] $guarded Plugin basenames, e.g. 'data-machine/data-machine.php'.
	 */
	$filtered = apply_filters( 'wp_coding_agents_guarded_runtime_plugins', $guarded );

	return is_array( $filtered ) ? array_values( array_filter( array_map( 'strval', $filtered ) ) ) : $guarded;
}

/**
 * Replace the Deactivate and Delete links with a short explanation.
 *
 * The owner is told why rather than shown a row with missing controls, which
 * reads as a broken page.
 *
 * @param string[] $actions     Action links keyed by action.
 * @param string   $plugin_file Plugin basename.
 * @return string[]
 */
function wp_coding_agents_guard_plugin_action_links( $actions, $plugin_file ) {
	if ( ! is_array( $actions ) || ! in_array( (string) $plugin_file, wp_coding_agents_guarded_runtime_plugins(), true ) ) {
		return $actions;
	}

	unset( $actions['deactivate'], $actions['delete'] );

	$actions['wp-coding-agents-guard'] = '<span aria-label="' . esc_attr__( 'Required by this site\'s AI assistant', 'wp-coding-agents' ) . '">'
		. esc_html__( 'Required by your assistant', 'wp-coding-agents' )
		. '</span>';

	return $actions;
}
add_filter( 'plugin_action_links', 'wp_coding_agents_guard_plugin_action_links', 100, 2 );
add_filter( 'network_admin_plugin_action_links', 'wp_coding_agents_guard_plugin_action_links', 100, 2 );

/**
 * Reject a guarded deactivation or deletion request.
 *
 * Hiding the links is presentation only — the request can still be issued by
 * URL, by a bulk action, or by any code calling deactivate_plugins(). This is
 * the half that actually holds.
 *
 * Only wp-admin requests are refused. WP-CLI, WP-Cron, and REST are left alone
 * so operator recovery and programmatic management keep working.
 *
 * @param string|string[] $plugins Plugin basename(s) being acted on.
 * @return void
 */
function wp_coding_agents_block_guarded_deactivation( $plugins ): void {
	if ( ( defined( 'WP_CLI' ) && WP_CLI ) || wp_doing_cron() ) {
		return;
	}

	if ( ! function_exists( 'is_admin' ) || ! is_admin() ) {
		return;
	}

	$guarded  = wp_coding_agents_guarded_runtime_plugins();
	$requested = is_array( $plugins ) ? $plugins : array( $plugins );
	$blocked   = array_intersect( array_map( 'strval', $requested ), $guarded );

	if ( empty( $blocked ) ) {
		return;
	}

	wp_die(
		esc_html__(
			'This plugin runs your site\'s AI assistant and cannot be deactivated or deleted from here. Ask your site operator if you need it changed.',
			'wp-coding-agents'
		),
		esc_html__( 'Action not permitted', 'wp-coding-agents' ),
		array( 'response' => 403, 'back_link' => true )
	);
}
add_action( 'deactivate_plugin', 'wp_coding_agents_block_guarded_deactivation', 1 );
add_action( 'delete_plugin', 'wp_coding_agents_block_guarded_deactivation', 1 );
