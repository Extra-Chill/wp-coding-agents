<?php
/**
 * Plugin Name: wp-coding-agents — continuous owned-source reconcile
 * Description: Keeps the agent's editable source set and the operator's capture
 *              manifest in agreement with what is actually installed, as it
 *              changes. Managed by wp-coding-agents setup/upgrade — do not edit
 *              by hand.
 *
 * WHY THIS EXISTS
 *
 * Owned mode derives what the site owns rather than asking an operator to
 * declare it (#336). That derivation ran only during `upgrade.sh`, which is
 * enough for a plugin that already exists and useless for one the agent is
 * about to write: it creates the directory, and nothing recomputes anything
 * until somebody SSHes in and runs an upgrade. "Build me a booking plugin" then
 * ends in a support ticket, which is the thing managed hosting exists to remove.
 *
 * So the derivation is reactive. WordPress already knows when the installed set
 * changes — it fires hooks for it — and this listens.
 *
 * WHY THE DERIVATION LIVES HERE AND NOT IN THE INSTALLER
 *
 * It used to live in lib/owned-source-discovery.sh. Keeping it there and adding
 * a PHP copy for the reactive path would be two implementations of the same
 * safety rule, free to drift — the exact failure this project spent #336 and
 * #337 removing from the capture path. PHP wins the tie because it is the only
 * one of the two that can run from a WordPress hook. The installer calls this
 * through WP-CLI, so there is one implementation and one answer.
 *
 * WHAT IT WILL NOT DO
 *
 * It never widens on missing evidence. The wp.org signal is a transient; on a
 * fresh install, after a cache flush, or when wp.org is unreachable it is
 * absent, and treating absence as "nothing belongs to wp.org" would classify
 * every plugin as the site's — handing the agent write access to WooCommerce
 * and any payment gateway. Ownership is inferred only from the PRESENCE of
 * evidence. A signal that cannot be trusted produces no reconcile at all and
 * the last recorded set stands.
 *
 * That asymmetry is the whole safety argument, and it is why this file does not
 * simply invert the permission model. Allowing wp-content/plugins/** and
 * denying each known third-party would make creation frictionless in one step,
 * and would turn "can the agent edit the payment gateway" from a question about
 * the allow list into a question about the deny list — where a stale or
 * incomplete entry means yes.
 *
 * @package wp-coding-agents
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

if ( ! defined( 'WP_CODING_AGENTS_SOURCE_MODE_OPTION' ) ) {
	define( 'WP_CODING_AGENTS_SOURCE_MODE_OPTION', 'wp_coding_agents_source_mode' );
}
if ( ! defined( 'WP_CODING_AGENTS_OWNED_OPTION' ) ) {
	define( 'WP_CODING_AGENTS_OWNED_OPTION', 'wp_coding_agents_owned_sources' );
}
if ( ! defined( 'WP_CODING_AGENTS_NOT_OWNED_OPTION' ) ) {
	define( 'WP_CODING_AGENTS_NOT_OWNED_OPTION', 'wp_coding_agents_not_owned' );
}
if ( ! defined( 'WP_CODING_AGENTS_INVENTORY_OPTION' ) ) {
	define( 'WP_CODING_AGENTS_INVENTORY_OPTION', 'wp_coding_agents_inventory_hash' );
}

/**
 * Plugin slugs wp-coding-agents installs and updates itself.
 *
 * Not the site's: the agent's own runtime, replaced wholesale by the next
 * upgrade. Editing them in place loses the edit; capturing them would commit
 * the installer's source into the site's repository.
 *
 * @return string[]
 */
function wp_coding_agents_carried_slugs() {
	return apply_filters(
		'wp_coding_agents_carried_slugs',
		array( 'data-machine', 'data-machine-code', 'wp-codebox' )
	);
}

/**
 * How stale the wp.org signal may be before it stops counting as evidence.
 *
 * WordPress refreshes update transients roughly twice daily. Two days tolerates
 * a quiet site or a brief wp.org outage without tolerating a cleared cache.
 *
 * @return int Seconds.
 */
function wp_coding_agents_max_signal_age() {
	return (int) apply_filters( 'wp_coding_agents_max_signal_age', 2 * DAY_IN_SECONDS );
}

/**
 * Slugs wp.org knows about, across plugins and themes.
 *
 * Returns null when the signal is missing, empty, or stale — deliberately
 * distinct from an empty array, which would mean "wp.org genuinely knows of
 * nothing installed here" and is never a conclusion this should reach.
 *
 * @return string[]|null
 */
function wp_coding_agents_wporg_slugs() {
	$plugins = get_site_transient( 'update_plugins' );
	if ( ! $plugins || empty( $plugins->last_checked ) ) {
		return null;
	}

	$files = array_merge(
		array_keys( (array) ( $plugins->response ?? array() ) ),
		array_keys( (array) ( $plugins->no_update ?? array() ) )
	);
	// A transient listing no plugins is not evidence that none are known to
	// wp.org; it is evidence the check has not really run.
	if ( ! $files ) {
		return null;
	}
	if ( ( time() - (int) $plugins->last_checked ) > wp_coding_agents_max_signal_age() ) {
		return null;
	}

	$slugs = array();
	foreach ( $files as $file ) {
		$slugs[] = false !== strpos( $file, '/' )
			? substr( $file, 0, strpos( $file, '/' ) )
			: basename( $file, '.php' );
	}

	// Themes are a SEPARATE transient with its own freshness, and it has to be
	// gated independently. A fresh plugin signal alongside a missing theme
	// signal would leave every bundled theme unrecognised — so twentytwentyfive
	// would derive as the site's, become editable, and get captured. Same
	// fail-open danger as the plugin case, reached by a different door, and the
	// only reason it is not shipped is that a test asserted the bundled theme
	// was excluded rather than assuming it.
	$themes = get_site_transient( 'update_themes' );
	if ( ! $themes || empty( $themes->last_checked ) ) {
		return null;
	}
	$theme_slugs = array_merge(
		array_keys( (array) ( $themes->response ?? array() ) ),
		array_keys( (array) ( $themes->no_update ?? array() ) )
	);
	if ( ! $theme_slugs ) {
		return null;
	}
	if ( ( time() - (int) $themes->last_checked ) > wp_coding_agents_max_signal_age() ) {
		return null;
	}
	foreach ( $theme_slugs as $slug ) {
		$slugs[] = $slug;
	}

	return array_values( array_unique( $slugs ) );
}

/**
 * Derive the owned set as wp-content-relative paths.
 *
 * @return string[]|null Null when the wp.org signal cannot be trusted.
 */
function wp_coding_agents_derive_owned_sources() {
	$wporg = wp_coding_agents_wporg_slugs();
	if ( null === $wporg ) {
		return null;
	}

	if ( ! function_exists( 'get_plugins' ) ) {
		require_once ABSPATH . 'wp-admin/includes/plugin.php';
	}

	$excluded = wp_coding_agents_not_owned_slugs();
	$skip     = array_merge( $wporg, wp_coding_agents_carried_slugs(), $excluded );

	$owned = array();

	foreach ( array_keys( get_plugins() ) as $file ) {
		$slug = false !== strpos( $file, '/' )
			? substr( $file, 0, strpos( $file, '/' ) )
			: basename( $file, '.php' );
		// A single-file plugin has no directory of its own to own; capturing it
		// would mean capturing all of wp-content/plugins.
		if ( false === strpos( $file, '/' ) ) {
			continue;
		}
		if ( in_array( $slug, $skip, true ) ) {
			continue;
		}
		$owned[] = 'wp-content/plugins/' . $slug;
	}

	foreach ( array_keys( wp_get_themes() ) as $slug ) {
		if ( in_array( $slug, $skip, true ) ) {
			continue;
		}
		$owned[] = 'wp-content/themes/' . $slug;
	}

	sort( $owned );
	return $owned;
}

/**
 * Operator-declared slugs that are NOT the site's despite deriving as owned.
 *
 * @return string[]
 */
function wp_coding_agents_not_owned_slugs() {
	$raw = (string) get_option( WP_CODING_AGENTS_NOT_OWNED_OPTION, '' );
	$out = array();
	foreach ( preg_split( '/\s+/', $raw ) as $slug ) {
		$slug = trim( $slug );
		if ( '' !== $slug ) {
			$out[] = $slug;
		}
	}
	return $out;
}

/**
 * A cheap fingerprint of the installed set.
 *
 * Lets a reconcile be skipped when nothing relevant changed, so this can be
 * called from a frequently-firing hook without doing real work each time.
 *
 * @return string
 */
function wp_coding_agents_inventory_hash( $fresh = false ) {
	if ( ! function_exists( 'get_plugins' ) ) {
		require_once ABSPATH . 'wp-admin/includes/plugin.php';
	}
	// get_plugins() caches its directory scan for the life of the process. In a
	// web request that is exactly right — the cache is built and used within one
	// request. In a long-lived WP-CLI process it is a trap: `wp scaffold plugin`
	// loads WordPress BEFORE creating the directory, so the cache predates the
	// new plugin, the hash comes out unchanged, and the reconcile returns early
	// having seen nothing.
	//
	// That is precisely the case this file exists for, and it failed silently:
	// the hook fired, WordPress was loaded, and the answer was still "unchanged".
	// Busting the cache is scoped to callers that know the filesystem just
	// changed, so the per-request path keeps its cached scan.
	if ( $fresh ) {
		wp_cache_delete( 'plugins', 'plugins' );
	}
	$parts = array_merge( array_keys( get_plugins() ), array_keys( wp_get_themes() ) );
	sort( $parts );
	return md5( implode( '|', $parts ) . '|' . implode( '|', wp_coding_agents_not_owned_slugs() ) );
}

/**
 * Reconcile the owned set, the capture manifest, and the runtime permissions.
 *
 * @param bool $force Reconcile even when the installed set looks unchanged.
 * @return array{status:string,owned?:string[],reason?:string}
 */
function wp_coding_agents_reconcile_sources( $force = false, $fresh = false ) {
	if ( 'owned' !== get_option( WP_CODING_AGENTS_SOURCE_MODE_OPTION, '' ) ) {
		return array( 'status' => 'skipped', 'reason' => 'not owned mode' );
	}

	$hash = wp_coding_agents_inventory_hash( $fresh );
	if ( ! $force && $hash === get_option( WP_CODING_AGENTS_INVENTORY_OPTION, '' ) ) {
		return array( 'status' => 'unchanged' );
	}

	$owned = wp_coding_agents_derive_owned_sources();
	if ( null === $owned ) {
		// Never widen on missing evidence. The recorded set stands.
		return array( 'status' => 'deferred', 'reason' => 'wp.org signal missing or stale' );
	}
	if ( ! $owned ) {
		// Fail closed: a site that owns nothing gets no editable source, rather
		// than falling back to opening wp-content wholesale.
		return array( 'status' => 'deferred', 'reason' => 'derived an empty owned set' );
	}

	update_option( WP_CODING_AGENTS_OWNED_OPTION, implode( "\n", $owned ), false );
	update_option( WP_CODING_AGENTS_INVENTORY_OPTION, $hash, false );

	wp_coding_agents_write_manifest( $owned );
	wp_coding_agents_write_edit_permissions( $owned );

	/**
	 * Fires after the owned set has been reconciled.
	 *
	 * @param string[] $owned wp-content-relative paths.
	 */
	do_action( 'wp_coding_agents_sources_reconciled', $owned );

	return array( 'status' => 'reconciled', 'owned' => $owned );
}

/**
 * Restore group ownership and mode after an atomic replace.
 *
 * file_put_contents()+rename() creates a NEW inode owned by whoever ran it, at
 * the process umask. When this reconcile runs as root during an upgrade it
 * therefore replaced opencode.json with a root:root 0644 file — and the runtime
 * user could no longer write it, so every LATER reconcile silently failed to
 * update the permissions it exists to update.
 *
 * The reconcile broke the very file it needs to keep writing. Mirrors
 * service_file_normalize_perms() in lib/common.sh: 0664, group taken from the
 * containing directory, so both root and the web/runtime user can write.
 *
 * @param string $path
 * @return void
 */
function wp_coding_agents_normalize_written_file( $path ) {
	@chmod( $path, 0664 );
	$gid = @filegroup( dirname( $path ) );
	if ( false !== $gid ) {
		@chgrp( $path, $gid );
	}
}

/**
 * Project the owned set to the file out-of-band capture reads.
 *
 * Capture runs as a deliberately read-only identity that cannot read
 * wp-config.php, so it can never run WP-CLI and never reach this database.
 * Deliberately outside the site root: SITE_PATH is the web root, and a file
 * written there is fetchable over HTTP.
 *
 * @param string[] $owned
 * @return bool
 */
function wp_coding_agents_write_manifest( array $owned ) {
	$dir = '/var/lib/wp-coding-agents/' . wp_coding_agents_site_key();
	if ( ! is_dir( $dir ) || ! is_writable( $dir ) ) {
		return false;
	}
	$path = $dir . '/owned-sources';
	$tmp  = $path . '.tmp';
	if ( false === file_put_contents( $tmp, implode( "\n", $owned ) . "\n" ) ) {
		return false;
	}
	if ( ! rename( $tmp, $path ) ) {
		return false;
	}
	wp_coding_agents_normalize_written_file( $path );
	return true;
}

/**
 * The manifest is keyed by site so one host can serve several.
 *
 * @return string
 */
function wp_coding_agents_site_key() {
	$host = wp_parse_url( home_url(), PHP_URL_HOST );
	return $host ? $host : 'default';
}

/**
 * Rewrite permission.edit so the agent may edit exactly what it owns.
 *
 * KEY ORDER IS THE PRECEDENCE MECHANISM. OpenCode evaluates with findLast over
 * a ruleset built in JSON key order, so the broad denies have to be written
 * before the allows that carve exceptions out of them. Emitting the allows
 * first silently inverts the policy.
 *
 * @param string[] $owned
 * @return bool
 */
function wp_coding_agents_write_edit_permissions( array $owned ) {
	$file = trailingslashit( ABSPATH ) . 'opencode.json';
	if ( ! is_readable( $file ) || ! is_writable( $file ) ) {
		return false;
	}
	$data = json_decode( (string) file_get_contents( $file ), true );
	if ( ! is_array( $data ) || ! isset( $data['permission']['edit'] ) || ! is_array( $data['permission']['edit'] ) ) {
		return false;
	}

	$managed = array();
	foreach ( $data['permission']['edit'] as $pattern => $action ) {
		// Drop stale owned-source allows this install no longer declares, so a
		// component that stops being owned stops being editable.
		$is_stale_allow = 'allow' === $action
			&& ( 0 === strpos( $pattern, 'wp-content/plugins/' ) || 0 === strpos( $pattern, 'wp-content/themes/' ) )
			&& '/**' === substr( $pattern, -3 );
		if ( $is_stale_allow ) {
			continue;
		}
		$managed[ $pattern ] = $action;
	}

	foreach ( $owned as $path ) {
		$managed[ $path . '/**' ] = 'allow';
	}

	if ( $managed === $data['permission']['edit'] ) {
		return true;
	}

	$data['permission']['edit'] = $managed;
	$encoded                    = wp_json_encode( $data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES );
	if ( false === $encoded ) {
		return false;
	}
	$tmp = $file . '.tmp';
	if ( false === file_put_contents( $tmp, $encoded . "\n" ) ) {
		return false;
	}
	if ( ! rename( $tmp, $file ) ) {
		return false;
	}
	wp_coding_agents_normalize_written_file( $file );
	return true;
}

// ---------------------------------------------------------------------------
// Triggers
// ---------------------------------------------------------------------------

/**
 * Reconcile after anything that can change the installed set.
 *
 * The inventory hash makes a no-op call cheap, so these can be broad.
 */
foreach ( array( 'activated_plugin', 'deactivated_plugin', 'deleted_plugin', 'switch_theme', 'deleted_theme', 'upgrader_process_complete' ) as $wp_coding_agents_hook ) {
	add_action( $wp_coding_agents_hook, 'wp_coding_agents_reconcile_on_change', 20 );
}
unset( $wp_coding_agents_hook );

/**
 * Hook target that ignores its arguments.
 *
 * @return void
 */
function wp_coding_agents_reconcile_on_change() {
	wp_coding_agents_reconcile_sources();
}

/**
 * A plugin the agent SCAFFOLDS fires none of the hooks above — no install, no
 * activation, just a directory appearing. That is the case this file exists for,
 * and the first version handled it with an hourly sweep.
 *
 * An hour is not a latency, it is a wall. An agent that writes a plugin and then
 * cannot edit it until the next hour has to explain that to the person who asked
 * for the plugin, which is the friction managed hosting exists to remove. Worse,
 * it is unpredictable: sometimes instant, sometimes fifty-nine minutes, with no
 * way for the agent to tell which.
 *
 * So the sweep is a backstop, not the mechanism. Two deterministic triggers do
 * the real work.
 *
 * FIRST: WP-CLI, which is how a plugin actually gets scaffolded. `after_invoke`
 * fires in the SAME command that created the directory, so the reconcile lands
 * before the agent's next tool call — zero perceptible latency and no race.
 */
/**
 * Reconcile after a WP-CLI command, loading WordPress first if it is not.
 *
 * `wp scaffold plugin` does NOT load WordPress — verified with --debug on
 * h44lacrosse.com: zero WordPress bootstrap steps, yet the hook fires and names
 * this callback. WP-CLI includes the mu-plugin far enough to register the hook
 * and no further, so the callback ran in a context with no get_option(), the
 * reconcile bailed out, and a scaffolded plugin stayed uneditable — the exact
 * failure the hook was added to fix, now silent instead of slow.
 *
 * Scaffolding is precisely the case that matters here, so the callback loads
 * WordPress itself rather than declining. That cost is paid only on the handful
 * of commands hooked above, and only when WordPress was not already loaded.
 *
 * @return void
 */
function wp_coding_agents_reconcile_after_cli() {
	if ( ! function_exists( 'get_option' ) ) {
		$runner = class_exists( 'WP_CLI' ) ? WP_CLI::get_runner() : null;
		if ( ! $runner || ! method_exists( $runner, 'load_wordpress' ) ) {
			// Nothing safe to do. The bootstrap hook below will pick this up on
			// the next request that does load WordPress.
			return;
		}
		$runner->load_wordpress();
		if ( ! function_exists( 'get_option' ) ) {
			return;
		}
	}
	// $fresh: this fires immediately after a command that changed the plugin or
	// theme directory, which is the one situation where the cached scan is known
	// to be stale.
	wp_coding_agents_reconcile_sources( false, true );
}

if ( class_exists( 'WP_CLI' ) && method_exists( 'WP_CLI', 'add_hook' ) ) {
	foreach ( array( 'scaffold plugin', 'scaffold child-theme', 'plugin install', 'plugin delete', 'theme install', 'theme delete' ) as $wp_coding_agents_cli_cmd ) {
		WP_CLI::add_hook(
			'after_invoke:' . $wp_coding_agents_cli_cmd,
			'wp_coding_agents_reconcile_after_cli'
		);
	}
	unset( $wp_coding_agents_cli_cmd );
}

/**
 * SECOND: every WordPress bootstrap. The inventory hash makes the common case a
 * single option read, so this is affordable on `init` — and it means a directory
 * created by ANY means, including a bare mkdir from the agent's shell, is picked
 * up by the very next WordPress request or wp-cli command. On an active agent
 * that is seconds, not an hour, and it needs no cooperation from whatever
 * created the directory.
 */
add_action( 'init', 'wp_coding_agents_reconcile_on_change', 5 );

/**
 * The sweep remains as a backstop for a site nobody is touching — where no
 * request arrives to trigger the above — and is now the slow path rather than
 * the only path.
 */
add_action( 'wp_coding_agents_reconcile_cron', 'wp_coding_agents_reconcile_on_change' );
add_action(
	'init',
	function () {
		if ( ! wp_next_scheduled( 'wp_coding_agents_reconcile_cron' ) ) {
			wp_schedule_event( time() + 60, 'hourly', 'wp_coding_agents_reconcile_cron' );
		}
	}
);
