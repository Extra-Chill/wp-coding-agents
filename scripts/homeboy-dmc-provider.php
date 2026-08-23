<?php

declare(strict_types=1);

$operation = (string) ( $argv[1] ?? '' );
$provider  = (string) ( $argv[2] ?? '' );
$workspace = (string) ( $argv[3] ?? '' );
$value     = (string) ( $argv[4] ?? '' );
$base      = (string) ( $argv[5] ?? '' );

if ( ! in_array($operation, array( 'identity', 'safety', 'resolve', 'converge' ), true) || '' === $provider || '' === $workspace || '' === $value || ( 'converge' === $operation && '' === $base ) ) {
	fwrite(STDERR, "Usage: homeboy-dmc-provider.php <identity|safety|resolve|converge> <dmc-provider> <workspace-root> <handle|path|identity-token> [base-sha]\n");
	exit(2);
}

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
		} catch (Throwable $error) {
			fwrite(STDERR, $error->getMessage() . "\n");
			exit($error->getCode() > 0 && $error->getCode() < 256 ? $error->getCode() : 1);
		}
		if ( 'datamachine-code/worktree-safety/v1' !== ( $safety['schema'] ?? null ) ) {
			fwrite(STDERR, "DMC worktree provider returned an unsupported safety envelope.\n");
			exit(1);
		}
		$result = array(
			array(
				'handle'  => $payload['handle'] ?? '',
				'path'    => $payload['path'] ?? '',
				'branch'  => $payload['branch'] ?? '',
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
