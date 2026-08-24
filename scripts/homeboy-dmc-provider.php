<?php

declare(strict_types=1);

$operation = (string) ( $argv[1] ?? '' );

const HOMEBOY_DMC_TASK_MAX_CANDIDATES = 200;
const HOMEBOY_DMC_TASK_MAX_FIELD_BYTES = 4096;
const HOMEBOY_DMC_TASK_MAX_OUTPUT_BYTES = 131072;
const HOMEBOY_DMC_TASK_MAX_DMC_STDOUT_BYTES = 1048576;
const HOMEBOY_DMC_TASK_MAX_DMC_STDERR_BYTES = 65536;

/** @return array{status:int,stdout:string,stderr:string,overflow:?string} */
$run_bounded_command = static function ( array $command, int $stdout_limit, int $stderr_limit ): array {
	$process = proc_open($command, array( 1 => array( 'pipe', 'w' ), 2 => array( 'pipe', 'w' ) ), $pipes);
	if ( ! is_resource($process) ) {
		throw new RuntimeException('Could not start the DMC task worktree lookup.');
	}
	foreach ( $pipes as $pipe ) {
		stream_set_blocking($pipe, false);
	}
	$stdout = '';
	$stderr = '';
	while ( ! feof($pipes[1]) || ! feof($pipes[2]) ) {
		$read = array( $pipes[1], $pipes[2] );
		$write = null;
		$except = null;
		$ready = stream_select($read, $write, $except, 1);
		if ( false === $ready ) {
			foreach ( $pipes as $pipe ) { fclose($pipe); }
			proc_terminate($process);
			proc_close($process);
			throw new RuntimeException('Could not read the DMC task worktree lookup output.');
		}
		foreach ( $read as $pipe ) {
			$chunk = fread($pipe, 8192);
			if ( false === $chunk || '' === $chunk ) {
				continue;
			}
			$is_stdout = $pipe === $pipes[1];
			$current = $is_stdout ? $stdout : $stderr;
			$limit = $is_stdout ? $stdout_limit : $stderr_limit;
			if ( strlen($current) + strlen($chunk) > $limit ) {
				foreach ( $pipes as $open_pipe ) { fclose($open_pipe); }
				proc_terminate($process);
				$status = proc_close($process);
				return array( 'status' => $status, 'stdout' => $stdout, 'stderr' => $stderr, 'overflow' => $is_stdout ? 'stdout' : 'stderr' );
			}
			if ( $is_stdout ) {
				$stdout .= $chunk;
			} else {
				$stderr .= $chunk;
			}
		}
	}
	foreach ( $pipes as $pipe ) { fclose($pipe); }
	return array( 'status' => proc_close($process), 'stdout' => $stdout, 'stderr' => $stderr, 'overflow' => null );
};

$canonical_task_url = static function ( string $task_url ): string {
	$task_url = trim($task_url);
	$task_url = preg_split('/[?#]/', $task_url, 2)[0] ?? '';
	$task_url = rtrim($task_url, '/');
	return preg_replace_callback(
		'~^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]+)~',
		static function ( array $matches ): string {
			$authority = $matches[2];
			$prefix    = '';
			if ( str_contains($authority, '@') ) {
				list($prefix, $authority) = explode('@', $authority, 2);
				$prefix .= '@';
			}
			$scheme = strtolower($matches[1]);
			$port_separator = strrpos($authority, ':');
			$port = false === $port_separator ? '' : substr($authority, $port_separator + 1);
			if ( '' !== $port && ctype_digit($port) && ( ( 'http' === $scheme && 80 === (int) $port ) || ( 'https' === $scheme && 443 === (int) $port ) ) ) {
				$authority = substr($authority, 0, $port_separator);
			}
			return $scheme . '://' . $prefix . strtolower($authority);
		},
		$task_url
	) ?? '';
};

if ( 'resolve_task' === $operation ) {
	$task_url = $canonical_task_url((string) ( $argv[2] ?? '' ));
	$command  = array_slice($argv, 3);
	if ( '' === $task_url || array() === $command ) {
		fwrite(STDERR, "Usage: homeboy-dmc-provider.php resolve_task <task-url> <dmc-worktree-list-command...>\n");
		exit(2);
	}
	foreach ( $command as $index => $argument ) {
		if ( str_starts_with($argument, '--task-ref=') ) {
			$command[ $index ] = '--task-ref=' . $task_url;
		}
	}
	try {
		$capture = $run_bounded_command($command, HOMEBOY_DMC_TASK_MAX_DMC_STDOUT_BYTES, HOMEBOY_DMC_TASK_MAX_DMC_STDERR_BYTES);
	} catch (Throwable $error) {
		fwrite(STDERR, $error->getMessage() . "\n");
		exit(1);
	}
	if ( null !== $capture['overflow'] ) {
		fwrite(STDERR, 'DMC task worktree lookup exceeded its bounded ' . $capture['overflow'] . " capture.\n");
		exit(1);
	}
	$stdout = $capture['stdout'];
	$stderr = $capture['stderr'];
	$status = $capture['status'];
	if ( 0 !== $status ) {
		$overflow = json_decode($stdout, true);
		if ( is_array($overflow) && 'worktree_task_candidates_overflow' === ( $overflow['error']['code'] ?? $overflow['code'] ?? null ) ) {
			fwrite(STDERR, "DMC task worktree lookup exceeded its complete candidate bound.\n");
		} else {
			fwrite(STDERR, 'DMC task worktree lookup failed: ' . trim($stderr) . "\n");
		}
		exit($status > 0 && $status < 256 ? $status : 1);
	}
	try {
		$rows = json_decode($stdout, true, 512, JSON_THROW_ON_ERROR);
	} catch (Throwable $error) {
		fwrite(STDERR, 'DMC task worktree lookup returned invalid JSON: ' . $error->getMessage() . "\n");
		exit(1);
	}
	if ( ! is_array($rows) || ! array_is_list($rows) ) {
		fwrite(STDERR, "DMC task worktree lookup did not return a complete row array.\n");
		exit(1);
	}
	if ( count($rows) > HOMEBOY_DMC_TASK_MAX_CANDIDATES ) {
		fwrite(STDERR, "DMC task worktree lookup exceeded its complete candidate bound.\n");
		exit(1);
	}
	$result = array();
	foreach ( $rows as $row ) {
			$task   = is_array($row) && is_array($row['task_full'] ?? null) ? $row['task_full'] : null;
			$safety = is_array($row) && is_array($row['safety'] ?? null) ? $row['safety'] : null;
			if (
				! is_array($row) || ! is_array($task) || $task_url !== $canonical_task_url((string) ( $task['task_url'] ?? '' ))
				|| ! is_string($row['handle'] ?? null) || '' === $row['handle']
				|| ! is_string($row['path'] ?? null) || '' === $row['path']
			|| ! is_string($row['branch'] ?? null) || '' === $row['branch']
			|| ! is_array($safety) || ! is_bool($safety['dirty'] ?? null) || ! is_bool($safety['unpushed'] ?? null) || ! is_bool($safety['primary'] ?? null)
		) {
				fwrite(STDERR, "DMC task worktree lookup returned an incomplete or mismatched task candidate.\n");
			exit(1);
		}
		if ( strlen($row['handle']) > HOMEBOY_DMC_TASK_MAX_FIELD_BYTES || strlen($row['path']) > HOMEBOY_DMC_TASK_MAX_FIELD_BYTES || strlen($row['branch']) > HOMEBOY_DMC_TASK_MAX_FIELD_BYTES || strlen($task_url) > HOMEBOY_DMC_TASK_MAX_FIELD_BYTES ) {
			fwrite(STDERR, "DMC task worktree lookup field exceeds its bounded projection limit.\n");
			exit(1);
		}
			$result[] = array(
				'handle'   => $row['handle'],
				'path'     => $row['path'],
				'branch'   => $row['branch'],
				'task_url' => $task_url,
				'safety'   => $safety,
			);
		}
	if ( array() === $result ) {
		fwrite(STDOUT, json_encode(array( 'success' => false, 'error' => array( 'code' => 'worktree_not_found', 'message' => 'DMC has no worktrees for the requested task.' ) ), JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n");
		exit(42);
	}
	$serialized = json_encode($result, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
	if ( strlen($serialized) > HOMEBOY_DMC_TASK_MAX_OUTPUT_BYTES ) {
		fwrite(STDERR, "DMC task worktree lookup exceeds its bounded projection output.\n");
		exit(1);
	}
	fwrite(STDOUT, $serialized . "\n");
	exit(0);
}

if ( 'plan' === $operation ) {
	$command = array_slice($argv, 2);
	if ( array() === $command ) {
		fwrite(STDERR, "Usage: homeboy-dmc-provider.php plan <dmc-worktree-plan-command...>\n");
		exit(2);
	}
	$process = proc_open($command, array( 1 => array( 'pipe', 'w' ), 2 => array( 'pipe', 'w' ) ), $pipes);
	if ( ! is_resource($process) ) {
		fwrite(STDERR, "Could not start the DMC worktree plan command.\n");
		exit(1);
	}
	$stdout = stream_get_contents($pipes[1]);
	$stderr = stream_get_contents($pipes[2]);
	fclose($pipes[1]);
	fclose($pipes[2]);
	$status = proc_close($process);
	if ( 0 !== $status ) {
		$evidence = trim($stdout . "\n" . $stderr);
		if ( preg_match('/Disposition:\s*(unsafe|owner(?:ship)?[ _-]conflict)/i', $evidence, $matches) ) {
			$normalized = strtolower(str_replace(array( ' ', '-' ), '_', $matches[1]));
			$disposition = in_array($normalized, array( 'owner_conflict', 'ownership_conflict' ), true) ? 'owner_conflict' : 'unsafe';
			fwrite(STDERR, 'DMC worktree plan disposition: ' . $disposition . "\n");
			exit($status > 0 && $status < 256 ? $status : 1);
		}
		fwrite(STDERR, 'DMC worktree plan failed: ' . trim($stderr) . "\n");
		exit($status > 0 && $status < 256 ? $status : 1);
	}
	try {
		$plan = json_decode($stdout, true, 512, JSON_THROW_ON_ERROR);
	} catch (Throwable $error) {
		fwrite(STDERR, 'DMC worktree plan returned invalid JSON: ' . $error->getMessage() . "\n");
		exit(1);
	}
	if ( ! is_array($plan) || 1 !== ( $plan['version'] ?? null ) || ! is_string($plan['digest'] ?? null) || '' === $plan['digest'] ) {
		fwrite(STDERR, "DMC worktree plan returned an unsupported typed envelope.\n");
		exit(1);
	}
	$disposition = (string) ( $plan['disposition'] ?? '' );
	if ( ! in_array($disposition, array( 'create', 'exact_reuse', 'adoptable' ), true) ) {
		fwrite(STDERR, 'DMC worktree plan disposition: ' . ( $disposition ?: 'unknown' ) . "\n");
		exit(1);
	}
	$handle = $plan['handle'] ?? null;
	$path   = $plan['path'] ?? null;
	$branch = $plan['branch'] ?? null;
	if ( ! is_string($handle) || '' === $handle || ! is_string($path) || '' === $path || ! is_string($branch) || '' === $branch ) {
		fwrite(STDERR, "DMC worktree plan returned an incomplete typed destination.\n");
		exit(1);
	}
	$result = array( array( 'handle' => $handle, 'path' => $path, 'branch' => $branch, 'safety' => array( 'dirty' => false, 'unpushed' => false, 'primary' => false ) ) );
	fwrite(STDOUT, json_encode($result, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n");
	exit(0);
}

$provider  = (string) ( $argv[2] ?? '' );
$workspace = (string) ( $argv[3] ?? '' );
$value     = (string) ( $argv[4] ?? '' );
$base      = (string) ( $argv[5] ?? '' );

if ( ! in_array($operation, array( 'identity', 'safety', 'resolve', 'converge' ), true) || '' === $provider || '' === $workspace || '' === $value || ( 'converge' === $operation && '' === $base ) ) {
	fwrite(STDERR, "Usage: homeboy-dmc-provider.php <identity|safety|resolve|converge> <dmc-provider> <workspace-root> <handle|path|identity-token> [base-sha]\n");
	exit(2);
}

/** @return array<string,mixed> */
$read_inventory = static function ( array $command, string $repo = '' ): array {
	if ( array() === $command ) {
		throw new RuntimeException('DMC aggregate inventory command is required for resolve.');
	}
	if ( '' === $repo || 1 !== count(array_filter($command, static fn ( string $part ): bool => '{repo}' === $part))) {
		throw new RuntimeException('DMC worktree list requires the repository resolved from identity.');
	}
	$command = array_map(static fn ( string $part ): string => '{repo}' === $part ? $repo : $part, $command);
	$process = proc_open($command, array( 1 => array( 'pipe', 'w' ), 2 => array( 'pipe', 'w' ) ), $pipes);
	if ( ! is_resource($process) ) {
		throw new RuntimeException('Could not start the DMC aggregate inventory command.');
	}
	$stdout = stream_get_contents($pipes[1]);
	$stderr = stream_get_contents($pipes[2]);
	fclose($pipes[1]);
	fclose($pipes[2]);
	$status = proc_close($process);
	if ( 0 !== $status ) {
		throw new RuntimeException('DMC aggregate inventory failed: ' . trim($stderr), $status);
	}
	$inventory = json_decode($stdout, true, 512, JSON_THROW_ON_ERROR);
	if ( ! is_array($inventory) || 1 !== count($inventory) || ! is_array($inventory[0] ?? null) ) {
		throw new RuntimeException('DMC aggregate inventory did not return one typed worktree record.');
	}
	return $inventory[0];
};

$run_provider = static function ( string $provider_operation, string $provider_value, string $provider_base = '' ) use ( $provider, $workspace ): array {
	$command = array( PHP_BINARY, $provider, $provider_operation, $workspace, $provider_value );
	if ( '' !== $provider_base ) {
		$command[] = $provider_base;
	}
	$process = proc_open($command, array( 1 => array( 'pipe', 'w' ), 2 => array( 'pipe', 'w' ) ), $pipes);
	if ( ! is_resource($process) ) {
		throw new RuntimeException('Could not start the DMC worktree provider.');
	}
	$stdout = stream_get_contents($pipes[1]);
	$stderr = stream_get_contents($pipes[2]);
	fclose($pipes[1]);
	fclose($pipes[2]);
	$status = proc_close($process);
	if ( 0 !== $status ) {
		throw new RuntimeException('DMC worktree provider failed: ' . trim($stderr), $status);
	}
	$payload = json_decode($stdout, true, 512, JSON_THROW_ON_ERROR);
	if ( ! is_array($payload) ) {
		throw new RuntimeException('DMC worktree provider returned an invalid envelope.');
	}
	return $payload;
};

try {
	$identity_input = 'resolve' === $operation && str_starts_with($value, '/') ? basename($value) : $value;
	$payload        = $run_provider('resolve' === $operation ? 'identity' : $operation, $identity_input, 'converge' === $operation ? $base : '');
} catch (Throwable $error) {
	fwrite(STDERR, $error->getMessage() . "\n");
	exit($error->getCode() > 0 && $error->getCode() < 256 ? $error->getCode() : 1);
}

if ( 'identity' === $operation && in_array((string) ( $payload['status'] ?? '' ), array( 'not_owned', 'not_found' ), true) ) {
	$result = array( 'status' => 'not_owned', 'ownership' => 'not_owned' );
} elseif ( 'identity' === $operation && 'datamachine-code/worktree-identity/v1' === ( $payload['schema'] ?? null ) ) {
	$result = array(
		'schema'      => 'homeboy/worktree-provider-identity/v1',
		'provider_id' => 'dmc',
		'token'       => $payload['token'] ?? '',
		'handle'      => $payload['handle'] ?? '',
		'path'        => $payload['path'] ?? '',
		'branch'      => $payload['branch'] ?? '',
		'primary'     => $payload['primary'] ?? true,
		'latency_ms'  => $payload['latency_ms'] ?? 0,
		'budget_ms'   => 0,
	);
} elseif ( 'safety' === $operation && 'datamachine-code/worktree-safety/v1' === ( $payload['schema'] ?? null ) ) {
	$result = array(
		'schema'         => 'homeboy/worktree-provider-safety/v1',
		'identity_token' => $payload['identity_token'] ?? '',
		'observed_at'    => $payload['observed_at'] ?? '',
		'dirty'          => $payload['dirty'] ?? true,
		'unpushed'       => $payload['unpushed'] ?? true,
		'fresh'          => $payload['fresh'] ?? false,
		'latency_ms'     => $payload['latency_ms'] ?? 0,
		'budget_ms'      => 0,
	);
} elseif ( 'converge' === $operation && 'datamachine-code/worktree-convergence/v1' === ( $payload['schema'] ?? null ) && 'converged' === ( $payload['status'] ?? null ) && $value === ( $payload['identity_token'] ?? null ) && $base === ( $payload['base_sha'] ?? null ) ) {
	$result = array(
		'schema'         => 'homeboy/worktree-provider-convergence/v1',
		'identity_token' => $value,
		'base_sha'       => $base,
	);
} elseif ( 'resolve' === $operation && in_array((string) ( $payload['status'] ?? '' ), array( 'not_owned', 'not_found' ), true) ) {
	$result = array( 'success' => false, 'error' => array( 'code' => 'worktree_not_found', 'message' => 'DMC does not own the requested worktree.' ) );
} elseif ( 'resolve' === $operation && 'datamachine-code/worktree-identity/v1' === ( $payload['schema'] ?? null ) ) {
	if ( str_starts_with($value, '/') && $value !== ( $payload['path'] ?? null ) ) {
		$result = array( 'success' => false, 'error' => array( 'code' => 'worktree_not_found', 'message' => 'DMC does not own the requested canonical path.' ) );
	} else {
		try {
			$safety = $run_provider('safety', (string) ( $payload['token'] ?? '' ));
			$handle = (string) ( $payload['handle'] ?? '' );
			$repo = strstr($handle, '@', true);
			if ( false === $repo || '' === $repo ) {
				throw new RuntimeException('DMC identity did not provide a repository-scoped handle.');
			}
			$inventory = $read_inventory(array_slice($argv, 5), $repo);
		} catch (Throwable $error) {
			fwrite(STDERR, $error->getMessage() . "\n");
			exit($error->getCode() > 0 && $error->getCode() < 256 ? $error->getCode() : 1);
		}
		if ( 'datamachine-code/worktree-safety/v1' !== ( $safety['schema'] ?? null ) ) {
			fwrite(STDERR, "DMC worktree provider returned an unsupported safety envelope.\n");
			exit(1);
		}
		$task_url = $inventory['task_full']['task_url'] ?? null;
		$owner_site = $inventory['owner_full']['site'] ?? null;
		$owner_agent = $inventory['owner_full']['agent'] ?? null;
		$lineage_task_url = $inventory['metadata']['origin_task']['task_url'] ?? null;
		$lineage_site = $inventory['metadata']['origin_site'] ?? null;
		$lineage_agent = $inventory['metadata']['origin_agent'] ?? null;
		if (
			! is_string($task_url) || '' === $task_url
			|| ! is_string($owner_site) || '' === $owner_site
			|| ! is_string($owner_agent) || '' === $owner_agent
			|| $payload['handle'] !== ( $inventory['handle'] ?? null )
			|| $payload['path'] !== ( $inventory['path'] ?? null )
			|| $payload['branch'] !== ( $inventory['branch'] ?? null )
			|| $canonical_task_url($task_url) !== $canonical_task_url((string) $lineage_task_url)
			|| $owner_site !== $lineage_site
			|| $owner_agent !== $lineage_agent
		) {
			fwrite(STDERR, "DMC aggregate inventory does not prove tracker ownership for the standalone identity.\n");
			exit(1);
		}
		$result = array(
			array(
				'handle'  => $payload['handle'] ?? '',
				'path'    => $payload['path'] ?? '',
				'branch'  => $payload['branch'] ?? '',
				'task_url' => $canonical_task_url($task_url),
				'safety'  => array(
					'dirty'    => $safety['dirty'] ?? true,
					'unpushed' => $safety['unpushed'] ?? true,
					'primary'  => $payload['primary'] ?? true,
				),
			)
		);
	}
} else {
	fwrite(STDERR, "DMC worktree provider returned an unsupported envelope.\n");
	exit(1);
}

fwrite(STDOUT, json_encode($result, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n");
if ( 'resolve' === $operation && false === ( $result['success'] ?? true ) && 'worktree_not_found' === ( $result['error']['code'] ?? '' ) ) {
	exit(42);
}
