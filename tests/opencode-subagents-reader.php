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

$root = sys_get_temp_dir() . '/opencode-subagents-reader-' . getmypid();
mkdir( $root . '/coordinator', 0777, true );
$root = realpath( $root );
mkdir( $root . '/writer/skills/writer', 0777, true );
mkdir( $root . '/writer/references/writer', 0777, true );
mkdir( $root . '/writer/contexts', 0777, true );
file_put_contents( $root . '/coordinator/SOUL.md', "# Coordinator\n" );
file_put_contents( $root . '/writer/SOUL.md', "# Writer\n" );
file_put_contents( $root . '/writer/contexts/chat.md', "# Nested context\n" );
file_put_contents( $root . '/writer/skills/writer/SKILL.md', "---\nname: writer\n---\n" );
file_put_contents( $root . '/writer/references/writer/context.md', "reference\x00bytes" );
$outside = $root . '/outside.md';
file_put_contents( $outside, "must not leave WordPress\n" );

$agents = array(
	'coordinator' => new WP_Agent( 'Routes work', array( 'writer' ), array(), array( 'datamachine_agent_id' => 1 ) ),
	'writer'      => new WP_Agent( 'Writes prose', array(), array(
		'default_model' => 'openai/gpt-5',
		'skills'        => array( 'writer/SKILL.md' => $root . '/writer/skills/writer/SKILL.md' ),
		'references'    => array( 'writer/context.md' => $root . '/writer/references/writer/context.md' ),
	), array( 'datamachine_agent_id' => 2 ) ),
);

function sanitize_title( string $value ): string { return $value; }
function wp_get_agent( string $slug ): ?WP_Agent { global $agents; return $agents[ $slug ] ?? null; }
function wp_get_agents(): array { global $agents; return $agents; }
function wp_json_encode( $value, int $flags = 0 ): string { return json_encode( $value, $flags | JSON_THROW_ON_ERROR ); }
function trailingslashit( string $value ): string { return rtrim( $value, '/\\' ) . '/'; }
eval( 'namespace DataMachine\\Core\\FilesRepository; class DirectoryManager { public function resolve_agent_directory(array $context): string { return $GLOBALS["root"] . "/" . (1 === $context["agent_id"] ? "coordinator" : "writer"); } }' );
function wp_get_ability( string $slug ): object {
	if ( 'datamachine/list-injectable-memory-files' !== $slug ) {
		throw new RuntimeException( 'Unexpected ability.' );
	}
	return new class {
		public function execute( array $input ): array {
			$directory = $GLOBALS['root'] . '/' . ( 1 === $input['agent_id'] ? 'coordinator' : 'writer' );
			$files     = array( array( 'filename' => 'SOUL.md', 'layer' => 'agent', 'path' => $directory . '/SOUL.md' ) );
			if ( 2 === $input['agent_id'] ) {
				$files[] = array( 'filename' => 'contexts/chat.md', 'layer' => 'agent', 'path' => $directory . '/contexts/chat.md' );
			}
			return array( 'success' => true, 'files' => $files );
		}
	};
}

$embedded = isset( $argv[1] ) && '--embedded' === $argv[1];
$scenario = $argv[2] ?? '';
if ( 'outside' === $scenario ) {
	$agents['writer'] = new WP_Agent( 'Writes prose', array(), array(
		'skills' => array( 'writer/SKILL.md' => $outside ),
	), array( 'datamachine_agent_id' => 2 ) );
} elseif ( 'oversize' === $scenario ) {
	file_put_contents( $root . '/writer/references/writer/large.bin', str_repeat( 'x', 2 * 1024 * 1024 + 1 ) );
	$agents['writer'] = new WP_Agent( 'Writes prose', array(), array(
		'references' => array( 'writer/large.bin' => $root . '/writer/references/writer/large.bin' ),
	), array( 'datamachine_agent_id' => 2 ) );
} elseif ( 'graph-limit' === $scenario ) {
	$agents['coordinator'] = new WP_Agent( 'Routes work', array_fill( 0, 65, 'writer' ), array(), array( 'datamachine_agent_id' => 1 ) );
}
$args     = $embedded ? array( 'coordinator', 'embedded' ) : array( 'coordinator' );
ob_start();
$rejected = false;
try {
	require __DIR__ . '/../lib/read-opencode-subagent-graph.php';
} catch ( RuntimeException $error ) {
	$rejected = true;
	ob_end_clean();
}
if ( '' !== $scenario ) {
	if ( ! $rejected ) {
		fwrite( STDERR, "FAIL: unsafe embedded artifact was exported\n" );
		exit( 1 );
	}
	echo "ok: embedded reader rejects unsafe portable artifacts\n";
	exit( 0 );
}
if ( $rejected ) {
	throw $error;
}
$graph = json_decode( ob_get_clean(), true, 512, JSON_THROW_ON_ERROR );

if ( array( 'writer' ) !== $graph['nodes'][0]['subagents'] ||
	'openai/gpt-5' !== $graph['nodes'][1]['model'] ||
	array( 'writer/SKILL.md' ) !== $graph['nodes'][1]['skill_policy']['paths'] ) {
	fwrite( STDERR, "FAIL: reader did not project the registered relationship and declared artifacts\n" );
	exit( 1 );
}

if ( $embedded ) {
	if ( 'embedded' !== $graph['source_mode'] ||
		"---\nname: writer\n---\n" !== base64_decode( $graph['nodes'][1]['sources']['skills']['writer/SKILL.md'], true ) ||
		"# Nested context\n" !== base64_decode( $graph['nodes'][1]['sources']['instructions']['contexts/chat.md'], true ) ||
		false !== strpos( wp_json_encode( $graph ), $root ) ) {
		fwrite( STDERR, "FAIL: embedded reader did not return self-contained artifact content\n" );
		exit( 1 );
	}
} elseif ( $root . '/writer/skills/writer/SKILL.md' !== $graph['nodes'][1]['sources']['skills']['writer/SKILL.md'] ||
	$root . '/writer/references/writer/context.md' !== $graph['nodes'][1]['sources']['references']['writer/context.md'] ) {
	fwrite( STDERR, "FAIL: path-backed reader output changed\n" );
	exit( 1 );
}

echo "ok: Agents API subagents and Data Machine artifacts project into the graph\n";
