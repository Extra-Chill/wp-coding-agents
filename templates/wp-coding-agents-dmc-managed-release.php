<?php
/**
 * Plugin Name: wp-coding-agents - DMC managed release
 * Description: Connects copied Data Machine Code deployments to the wp-coding-agents official-release updater.
 */

defined( 'ABSPATH' ) || exit;

function wp_coding_agents_dmc_upgrade_command(): string {
	return escapeshellarg( '@WP_CODING_AGENTS_UPGRADE_SCRIPT@' ) . ' --plugins-only --wp-path ' . escapeshellarg( ABSPATH );
}

function wp_coding_agents_dmc_release_status(): array {
	$raw = shell_exec( wp_coding_agents_dmc_upgrade_command() . ' --dmc-managed-release-status 2>/dev/null' );
	$status = is_string( $raw ) ? json_decode( $raw, true ) : null;
	return is_array( $status ) ? $status : array();
}

function wp_coding_agents_dmc_read_version(): string {
	$file = WP_PLUGIN_DIR . '/data-machine-code/data-machine-code.php';
	$body = is_readable( $file ) ? (string) file_get_contents( $file ) : '';
	return preg_match( '/^\s*\*\s*Version:\s*(.+)$/mi', $body, $matches ) ? trim( $matches[1] ) : '';
}

add_filter( 'datamachine_code_managed_release_channel', static function( array $channel ): array {
	$status = wp_coding_agents_dmc_release_status();
	if ( 'copied_deploy' !== ( $status['deployment'] ?? '' ) || empty( $status['latest_version'] ) ) {
		return $channel;
	}
	return array(
		'id' => 'wp-coding-agents-official-release',
		'latest_version' => (string) $status['latest_version'],
		'action' => array( 'type' => 'command', 'command' => wp_coding_agents_dmc_upgrade_command(), 'authorize_callback' => true ),
		'converge' => static function(): array { return array( 'success' => 0 === (int) shell_exec( wp_coding_agents_dmc_upgrade_command() . ' >/dev/null 2>&1; echo $?' ) ); },
		'read_installed_version' => 'wp_coding_agents_dmc_read_version',
		'verify' => static function( string $version ) use ( $status ): array {
			$provenance = WP_PLUGIN_DIR . '/data-machine-code/.wp-coding-agents-release-current/.wp-coding-agents-managed-release.json';
			$record = is_readable( $provenance ) ? json_decode( (string) file_get_contents( $provenance ), true ) : null;
			return is_array( $record ) && $version === ( $record['version'] ?? '' ) && $version === ( $status['latest_version'] ?? '' ) ? array( 'state' => 'verified' ) : array( 'state' => 'unverified' );
		},
	);
} );

add_filter( 'datamachine_code_runtime_source_doctor_config', static function( array $config ): array {
	$config['command_contract'] = array( 'command' => 'datamachine-code runtime release', 'flag' => '--apply' );
	return $config;
} );
