<?php
/** Contract coverage for the Agents API/Data Machine graph reader. */

final class WP_Agent {
	public function __construct(
		private string $description,
		private array $subagents,
		private array $config,
		private array $meta
	) {}
	public function get_description(): string { return $this->description; }
	public function get_subagents(): array { return $this->subagents; }
	public function get_default_config(): array { return $this->config; }
	public function get_meta(): array { return $this->meta; }
}

$agents = array(
	'coordinator' => new WP_Agent( 'Routes work', array( 'writer' ), array(), array( 'datamachine_agent_id' => 1 ) ),
	'writer'      => new WP_Agent( 'Writes prose', array(), array(
		'default_model' => 'openai/gpt-5',
		'skills'        => array( 'writer/SKILL.md' => '/agents/writer/skills/writer/SKILL.md' ),
		'references'    => array( 'writer/context.md' => '/agents/writer/references/writer/context.md' ),
	), array( 'datamachine_agent_id' => 2 ) ),
);

function sanitize_title( string $value ): string { return $value; }
function wp_get_agent( string $slug ): ?WP_Agent { global $agents; return $agents[ $slug ] ?? null; }
function wp_get_agents(): array { global $agents; return $agents; }
function wp_json_encode( $value, int $flags = 0 ): string { return json_encode( $value, $flags | JSON_THROW_ON_ERROR ); }
function wp_get_ability( string $slug ): object {
	if ( 'datamachine/list-injectable-memory-files' !== $slug ) {
		throw new RuntimeException( 'Unexpected ability.' );
	}
	return new class {
		public function execute( array $input ): array {
			return array( 'success' => true, 'files' => array(
				array( 'filename' => 'SOUL.md', 'path' => '/agents/' . ( 1 === $input['agent_id'] ? 'coordinator' : 'writer' ) . '/SOUL.md' ),
			) );
		}
	};
}

$args = array( 'coordinator' );
ob_start();
require __DIR__ . '/../lib/read-opencode-subagent-graph.php';
$graph = json_decode( ob_get_clean(), true, 512, JSON_THROW_ON_ERROR );

if ( array( 'writer' ) !== $graph['nodes'][0]['subagents'] ||
	'openai/gpt-5' !== $graph['nodes'][1]['model'] ||
	'/agents/writer/skills/writer/SKILL.md' !== $graph['nodes'][1]['sources']['skills']['writer/SKILL.md'] ||
	'/agents/writer/references/writer/context.md' !== $graph['nodes'][1]['sources']['references']['writer/context.md'] ||
	array( 'writer/SKILL.md' ) !== $graph['nodes'][1]['skill_policy']['paths'] ) {
	fwrite( STDERR, "FAIL: reader did not project the registered relationship and declared artifacts\n" );
	exit( 1 );
}

echo "ok: Agents API subagents and Data Machine artifacts project into the graph\n";
