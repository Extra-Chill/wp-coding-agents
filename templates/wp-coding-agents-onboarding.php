<?php
/**
 * Plugin Name: wp-coding-agents — personal onboarding
 * Description: Async, opt-in personal introductions. Managed by setup/upgrade.
 */
defined( 'ABSPATH' ) || exit;

class WpCodingAgents_Onboarding {
	const JOB = 'wp_coding_agents_onboarding_intro';

	public static function targets(): array {
		$value = apply_filters( 'wp_coding_agents_onboarding_targets', get_option( 'wp_coding_agents_onboarding_targets', array() ) );
		return is_array( $value ) ? $value : array();
	}

	public static function granted( $agent_id, $type, $id, $role, $previous_role = null, $context = array() ): void {
		if ( 'user' === $type && (int) $id > 0 ) {
			self::queue( (int) $id );
		}
	}

	public static function queue( int $user_id ): void {
		if ( ! self::targets() ) {
			return;
		}
		$args = array( $user_id );
		if ( ! wp_next_scheduled( self::JOB, $args ) ) {
			$result = wp_schedule_single_event( time() + 1, self::JOB, $args, true );
			if ( is_wp_error( $result ) || false === $result ) {
				error_log( 'wp-coding-agents onboarding: could not schedule intro' );
			}
		}
	}

	public static function run( int $user_id ): void {
		try {
			if ( ! class_exists( '\DataMachine\Core\Database\Agents\Agents' ) || ! class_exists( '\DataMachine\Core\Agents\ChatIdentityLinks' ) ) {
				return;
			}
			$agents = new \DataMachine\Core\Database\Agents\Agents();
			$access = new \DataMachine\Core\Database\Agents\AgentAccess();
			foreach ( self::targets() as $slug => $platforms ) {
				$agent = $agents->get_by_slug( $slug );
				$grant = $agent ? $access->get_access( (string) $agent['agent_id'], $user_id ) : null;
				if ( ! $grant || ! is_array( $platforms ) ) {
					continue;
				}
				$key = '_wp_coding_agents_intro_' . hash( 'sha256', (string) $agent['agent_id'] );
				if ( get_user_meta( $user_id, $key, true ) ) {
					continue;
				}
				foreach ( $platforms as $platform => $target ) {
					if ( ! is_array( $target ) || empty( $target['cli_channel'] ) || empty( $target['recipient'] ) ) {
						continue;
					}
					$links = \DataMachine\Core\Agents\ChatIdentityLinks::list_links( $user_id, $platform );
					foreach ( $links as $link ) {
						if ( \DataMachine\Core\Agents\ChatIdentityLinks::resolve_user_id( $platform, $link['actor_id'] ) !== $user_id ) {
							continue;
						}
						$input = array( 'channel' => $target['cli_channel'], 'recipient' => (string) $target['recipient'] );
						$config = WpCodingAgents_Cli_Channel_Registry::lookup( $input['channel'] );
						// A bridge must explicitly implement safe personal-thread dispatch.
						$config = apply_filters( 'wp_coding_agents_onboarding_cli_config', null, $config, $target, $link, $grant->role, $slug, $user_id );
						if ( ! is_array( $config ) ) {
							continue;
						}
						// Atomic DB option claim, shared by concurrent cron workers. Retain on
						// ambiguous delivery failure: retrying could create a second thread.
						$claim = 'wp_coding_agents_intro_claim_' . hash( 'sha256', $user_id . ':' . $agent['agent_id'] );
						if ( ! add_option( $claim, time(), '', false ) ) {
							break 2;
						}
						$result = WpCodingAgents_Cli_Channel_Transport::execute_config( $config, $input );
						if ( is_wp_error( $result ) || empty( $result['sent'] ) ) {
							error_log( 'wp-coding-agents onboarding: intro dispatch failed; inspect claim before retry' );
						} else {
							update_user_meta( $user_id, $key, time() );
						}
						break 2;
					}
				}
			}
		} catch ( \Throwable $error ) {
			error_log( 'wp-coding-agents onboarding: intro worker failed (' . get_class( $error ) . ')' );
		}
	}
}
add_action( 'datamachine_agent_access_granted', array( 'WpCodingAgents_Onboarding', 'granted' ), 10, 6 );
add_action( 'datamachine_chat_identity_linked', array( 'WpCodingAgents_Onboarding', 'queue' ), 10, 1 );
add_action( WpCodingAgents_Onboarding::JOB, array( 'WpCodingAgents_Onboarding', 'run' ) );

// Roadie adapter: vendor arguments and mention syntax stay outside the generic worker.
add_filter( 'wp_coding_agents_onboarding_cli_config', function ( $existing, $config, $target, $link, $role, $slug, $user_id ) {
	if ( null !== $existing || ! in_array( $target['cli_channel'], array( 'roadie', 'roadie-notify' ), true ) || ! is_array( $config ) || 'discord' !== $link['platform'] ) {
		return $existing;
	}
	$mention = '<@' . $link['actor_id'] . '>';
	$prompt = "Welcome {$mention} personally. Write a short, friendly, plain-language intro: who you are, that they can just talk to you here, and a few concrete things you can do under their own account. Tell them to run /connect: one sign-in connects their tools. End by asking what they want to try. Do not claim their tools are connected or use the operator's account.";
	$prompt = apply_filters( 'wp_coding_agents_onboarding_prompt', $prompt, $slug, $user_id, $link );
	// Capability probe is bounded and runs only in the async worker. Older
	// Roadie releases keep the /connect prompt without an unsupported flag.
	$probe = $config;
	$probe['args'] = array( 'send', '--help' );
	$probe['timeout'] = 5;
	$probe['capture_output'] = true;
	$help = WpCodingAgents_Cli_Channel_Transport::execute_config( $probe, array( 'channel' => $target['cli_channel'] ) );
	$welcome = ! is_wp_error( $help ) && preg_match( '/(?:^|\\s)--welcome-person(?:[\\s,]|$)/m', $help['metadata']['stdout'] ?? '' );
	$config['args'] = array( 'send', '--channel', (string) $target['recipient'], '--user', $link['actor_id'], '--name', 'Welcome 👋', '--prompt', $prompt );
	if ( $welcome ) {
		$config['args'][] = '--welcome-person';
	}
	// Restrict the proactive CLI turn too: --user adds a member, not a seat.
	if ( 'admin' !== $role ) {
		foreach ( array( 'bash:deny', 'edit:deny', 'external_directory:deny', 'read:*wp-config.php:deny', 'grep:*wp-config.php:deny' ) as $rule ) {
			$config['args'][] = '--permission';
			$config['args'][] = $rule;
		}
	}
	return $config;
}, 10, 8 );
