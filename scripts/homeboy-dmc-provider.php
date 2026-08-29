<?php

declare(strict_types=1);

$operation = (string) ( $argv[1] ?? '' );

const HOMEBOY_DMC_TASK_MAX_CANDIDATES = 200;
const HOMEBOY_DMC_TASK_MAX_FIELD_BYTES = 4096;
const HOMEBOY_DMC_TASK_MAX_OUTPUT_BYTES = 131072;
const HOMEBOY_DMC_TASK_MAX_DMC_STDOUT_BYTES = 1048576;
const HOMEBOY_DMC_TASK_MAX_DMC_STDERR_BYTES = 65536;
// Leave enough of Homeboy's 12-second supervision window to reap the DMC session
// and report a typed adapter failure instead of being terminated externally.
const HOMEBOY_DMC_TASK_LOOKUP_TIMEOUT_SECONDS = 8;
const HOMEBOY_DMC_TASK_TERMINATION_GRACE_SECONDS = 1;
const HOMEBOY_DMC_ATTACHMENT_TIMEOUT_SECONDS = 30;

if ( '_session_exec' === $operation ) {
	$command = array_slice($argv, 2);
	if ( array() === $command || ! function_exists('posix_setsid') || ! function_exists('pcntl_exec') || -1 === posix_setsid() ) {
		fwrite(STDERR, "Could not isolate the DMC task worktree lookup session.\n");
		exit(1);
	}
	$ready = fopen('php://fd/3', 'w');
	if ( false === $ready ) {
		fwrite(STDERR, "Could not confirm the isolated DMC task worktree lookup session.\n");
		exit(1);
	}
	fwrite($ready, "ready\n");
	fclose($ready);
	$executable = $command[0];
	if ( ! str_contains($executable, DIRECTORY_SEPARATOR) ) {
		foreach ( explode(PATH_SEPARATOR, (string) getenv('PATH')) as $directory ) {
			$candidate = rtrim($directory, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . $executable;
			if ( is_file($candidate) && is_executable($candidate) ) {
				$executable = $candidate;
				break;
			}
		}
	}
	pcntl_exec($executable, array_slice($command, 1));
	fwrite(STDERR, "Could not start the isolated DMC task worktree lookup.\n");
	exit(1);
}

/** @return array{status:int,stdout:string,stderr:string,failure:?string} */
$run_bounded_command = static function ( array $command, int $stdout_limit, int $stderr_limit, int $timeout_seconds = HOMEBOY_DMC_TASK_LOOKUP_TIMEOUT_SECONDS ): array {
	$launcher = array_merge(array( PHP_BINARY, __FILE__, '_session_exec' ), $command);
	$process = proc_open($launcher, array( 1 => array( 'pipe', 'w' ), 2 => array( 'pipe', 'w' ), 3 => array( 'pipe', 'w' ) ), $pipes);
	if ( ! is_resource($process) ) {
		throw new RuntimeException('Could not start the DMC task worktree lookup.');
	}
	$state = proc_get_status($process);
	$pid = is_array($state) && is_int($state['pid'] ?? null) ? $state['pid'] : null;
	foreach ( $pipes as $pipe ) {
		stream_set_blocking($pipe, false);
	}
	$stdout = '';
	$stderr = '';
	$session_ready = false;
	$failure = null;
	$termination_started_at = null;
	$started_at = microtime(true);
	while ( true ) {
		$child_running = (bool) ( proc_get_status($process)['running'] ?? false );
		if ( feof($pipes[1]) && feof($pipes[2]) && feof($pipes[3]) && ! $child_running ) {
			break;
		}
		if ( ! $session_ready && feof($pipes[3]) && null === $failure ) {
			$failure = 'session';
			$termination_started_at = microtime(true);
		}
		if ( null === $failure && microtime(true) - $started_at >= $timeout_seconds ) {
			$failure = 'timeout';
			$termination_started_at = microtime(true);
		}
		if ( null !== $failure ) {
			$signal = microtime(true) - (float) $termination_started_at >= HOMEBOY_DMC_TASK_TERMINATION_GRACE_SECONDS ? SIGKILL : SIGTERM;
			if ( $session_ready && null !== $pid && $pid > 0 ) {
				@posix_kill(-$pid, $signal);
			} else {
				proc_terminate($process, $signal);
			}
		}
		$read = array_filter($pipes, static fn ( $pipe ): bool => is_resource($pipe) && ! feof($pipe));
		if ( array() === $read ) {
			usleep(100000);
			continue;
		}
		$write = null;
		$except = null;
		$ready = stream_select($read, $write, $except, 0, 100000);
		if ( false === $ready ) {
			foreach ( $pipes as $pipe ) { if ( is_resource($pipe) ) { fclose($pipe); } }
			if ( $session_ready && null !== $pid && $pid > 0 ) {
				@posix_kill(-$pid, SIGKILL);
			} else {
				proc_terminate($process, SIGKILL);
			}
			proc_close($process);
			throw new RuntimeException('Could not read the DMC task worktree lookup output.');
		}
		foreach ( $read as $pipe ) {
			$chunk = fread($pipe, 8192);
			if ( false === $chunk || '' === $chunk ) {
				continue;
			}
			if ( $pipe === $pipes[3] ) {
				$session_ready = 'ready' === trim($chunk);
				if ( ! $session_ready ) {
					$failure = 'session';
					$termination_started_at = microtime(true);
				}
				continue;
			}
			if ( null !== $failure ) {
				continue;
			}
			$is_stdout = $pipe === $pipes[1];
			$current = $is_stdout ? $stdout : $stderr;
			$limit = $is_stdout ? $stdout_limit : $stderr_limit;
			if ( strlen($current) + strlen($chunk) > $limit ) {
				$failure = $is_stdout ? 'stdout' : 'stderr';
				$termination_started_at = microtime(true);
				continue;
			}
			if ( $is_stdout ) {
				$stdout .= $chunk;
			} else {
				$stderr .= $chunk;
			}
		}
	}
	foreach ( $pipes as $pipe ) { if ( is_resource($pipe) ) { fclose($pipe); } }
	// Reap the leader before probing its group so a Linux zombie cannot keep kill(-pgid, 0) true.
	$status = proc_close($process);
	while ( $session_ready && null !== $pid && $pid > 0 && @posix_kill(-$pid, 0) ) {
		if ( null === $failure && microtime(true) - $started_at >= $timeout_seconds ) {
			$failure = 'timeout';
			$termination_started_at = microtime(true);
		}
		if ( null !== $failure ) {
			$signal = microtime(true) - (float) $termination_started_at >= HOMEBOY_DMC_TASK_TERMINATION_GRACE_SECONDS ? SIGKILL : SIGTERM;
			@posix_kill(-$pid, $signal);
		}
		usleep(100000);
	}
	return array( 'status' => $status, 'stdout' => $stdout, 'stderr' => $stderr, 'failure' => $failure );
};

$decode_json_output = static function ( string $stdout ): mixed {
	try {
		return json_decode(trim($stdout), true, 512, JSON_THROW_ON_ERROR);
	} catch (JsonException $original_error) {
		$lines = preg_split('/\R/', $stdout);
		if ( false === $lines ) {
			throw $original_error;
		}
		$diagnostic_found = false;
		while ( array() !== $lines ) {
			$line = array_shift($lines);
			if ( '' === trim($line) ) {
				continue;
			}
			if ( preg_match('/^(?:PHP )?(?:Deprecated|Warning|Notice):\s/', ltrim($line)) ) {
				$diagnostic_found = true;
				continue;
			}
			array_unshift($lines, $line);
			break;
		}
		if ( ! $diagnostic_found ) {
			throw $original_error;
		}
		return json_decode(trim(implode("\n", $lines)), true, 512, JSON_THROW_ON_ERROR);
	}
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

$task_attachment_result = static function ( array $identity, string $task_url, string $status ): array {
	return array(
		'schema'      => 'homeboy/worktree-provider-task-attachment/v1',
		'provider_id' => 'dmc',
		'handle'      => $identity['handle'],
		'task_url'    => $task_url,
		'path'        => $identity['path'],
		'branch'      => $identity['branch'],
		'primary'     => false,
		'status'      => $status,
	);
};

if ( 'task_attachment_preview' === $operation ) {
	$provider  = (string) ( $argv[2] ?? '' );
	$workspace = (string) ( $argv[3] ?? '' );
	$handle    = (string) ( $argv[4] ?? '' );
	$task_url  = $canonical_task_url((string) ( $argv[5] ?? '' ));
	if ( '' === $provider || '' === $workspace || '' === $handle || '' === $task_url ) {
		fwrite(STDERR, "Usage: homeboy-dmc-provider.php task_attachment_preview <dmc-provider> <workspace-root> <handle> <task-url>\n");
		exit(2);
	}
	try {
		$identity_capture = $run_bounded_command(array( PHP_BINARY, $provider, 'identity', $workspace, $handle ), HOMEBOY_DMC_TASK_MAX_OUTPUT_BYTES, HOMEBOY_DMC_TASK_MAX_DMC_STDERR_BYTES);
	} catch (Throwable $error) {
		fwrite(STDERR, $error->getMessage() . "\n");
		exit(1);
	}
	if ( null !== $identity_capture['failure'] ) {
		fwrite(STDERR, "DMC tracker-attachment preview exceeded its bounded execution or capture.\n");
		exit(1);
	}
	if ( 0 !== $identity_capture['status'] ) {
		fwrite(STDERR, $identity_capture['stderr']);
		exit($identity_capture['status'] > 0 && $identity_capture['status'] < 256 ? $identity_capture['status'] : 1);
	}
	try {
		$identity = $decode_json_output($identity_capture['stdout']);
	} catch (Throwable $error) {
		fwrite(STDERR, "DMC tracker-attachment preview returned invalid identity JSON.\n");
		exit(1);
	}
	if ( is_array($identity) && in_array((string) ( $identity['status'] ?? '' ), array( 'not_owned', 'not_found' ), true) ) {
		fwrite(STDOUT, "{\"status\":\"not_owned\"}\n");
		exit(0);
	}
	if (
		! is_array($identity) || 'datamachine-code/worktree-identity/v1' !== ( $identity['schema'] ?? null )
		|| $handle !== ( $identity['handle'] ?? null ) || ! is_string($identity['path'] ?? null) || '' === $identity['path']
		|| ! is_string($identity['branch'] ?? null) || '' === $identity['branch'] || false !== ( $identity['primary'] ?? null )
	) {
		fwrite(STDERR, "DMC tracker-attachment preview returned an incomplete exact identity.\n");
		exit(1);
	}
	$existing_task_url = $canonical_task_url((string) ( $identity['task_url'] ?? '' ));
	if ( '' !== $existing_task_url && $task_url !== $existing_task_url ) {
		fwrite(STDERR, "DMC worktree already has conflicting tracker ownership.\n");
		exit(1);
	}
	if ( '' === $existing_task_url ) {
		try {
			$safety_capture = $run_bounded_command(array( PHP_BINARY, $provider, 'safety', $workspace, (string) ( $identity['token'] ?? '' ) ), HOMEBOY_DMC_TASK_MAX_OUTPUT_BYTES, HOMEBOY_DMC_TASK_MAX_DMC_STDERR_BYTES);
		} catch (Throwable $error) {
			fwrite(STDERR, $error->getMessage() . "\n");
			exit(1);
		}
		if ( null !== $safety_capture['failure'] ) {
			fwrite(STDERR, "DMC tracker-attachment preview exceeded its bounded execution or capture.\n");
			exit(1);
		}
		if ( 0 !== $safety_capture['status'] ) {
			fwrite(STDERR, $safety_capture['stderr']);
			exit($safety_capture['status'] > 0 && $safety_capture['status'] < 256 ? $safety_capture['status'] : 1);
		}
		$safety = $decode_json_output($safety_capture['stdout']);
		if ( ! is_array($safety) || 'datamachine-code/worktree-safety/v1' !== ( $safety['schema'] ?? null ) || true !== ( $safety['fresh'] ?? null ) || false !== ( $safety['dirty'] ?? null ) ) {
			fwrite(STDERR, "DMC tracker-attachment preview requires a fresh clean worktree.\n");
			exit(1);
		}
	}
	fwrite(STDOUT, json_encode($task_attachment_result($identity, $task_url, '' === $existing_task_url ? 'eligible' : 'already_attached'), JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n");
	exit(0);
}

if ( 'task_attachment_apply' === $operation ) {
	$handle   = (string) ( $argv[2] ?? '' );
	$task_url = $canonical_task_url((string) ( $argv[3] ?? '' ));
	$command  = array_slice($argv, 4);
	if ( '' === $handle || '' === $task_url || array() === $command ) {
		fwrite(STDERR, "Usage: homeboy-dmc-provider.php task_attachment_apply <handle> <task-url> <dmc-attach-tracker-command...>\n");
		exit(2);
	}
	foreach ( $command as $index => $argument ) {
		$command[ $index ] = str_replace(array( '{handle}', '{task_url}' ), array( $handle, $task_url ), $argument);
	}
	try {
		$capture = $run_bounded_command($command, HOMEBOY_DMC_TASK_MAX_DMC_STDOUT_BYTES, HOMEBOY_DMC_TASK_MAX_DMC_STDERR_BYTES, HOMEBOY_DMC_ATTACHMENT_TIMEOUT_SECONDS);
	} catch (Throwable $error) {
		fwrite(STDERR, $error->getMessage() . "\n");
		exit(1);
	}
	if ( null !== $capture['failure'] ) {
		fwrite(STDERR, "DMC tracker attachment exceeded its bounded execution or capture.\n");
		exit(1);
	}
	if ( 0 !== $capture['status'] ) {
		fwrite(STDERR, $capture['stderr']);
		exit($capture['status'] > 0 && $capture['status'] < 256 ? $capture['status'] : 1);
	}
	try {
		$attached = $decode_json_output($capture['stdout']);
	} catch (Throwable $error) {
		fwrite(STDERR, "DMC tracker attachment returned invalid JSON.\n");
		exit(1);
	}
	$identity = is_array($attached) && is_array($attached['provider_resolution'] ?? null) ? $attached['provider_resolution'] : null;
	$status   = is_array($attached) ? (string) ( $attached['status'] ?? '' ) : '';
	if (
		! is_array($identity) || ! in_array($status, array( 'attached', 'already_attached' ), true)
		|| $handle !== ( $attached['handle'] ?? null ) || $handle !== ( $identity['handle'] ?? null )
		|| $task_url !== $canonical_task_url((string) ( $identity['task_url'] ?? '' ))
		|| ! is_string($identity['path'] ?? null) || '' === $identity['path'] || ! is_string($identity['branch'] ?? null) || '' === $identity['branch']
		|| false !== ( $identity['primary'] ?? null )
	) {
		fwrite(STDERR, "DMC tracker attachment returned incomplete or mismatched exact evidence.\n");
		exit(1);
	}
	fwrite(STDOUT, json_encode($task_attachment_result($identity, $task_url, $status), JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n");
	exit(0);
}

if ( 'resolve_task_standalone' === $operation ) {
	$task_url = $canonical_task_url((string) ( $argv[2] ?? '' ));
	$provider = (string) ( $argv[3] ?? '' );
	$workspace = (string) ( $argv[4] ?? '' );
	if ( '' === $task_url || '' === $provider || '' === $workspace ) {
		fwrite(STDERR, "Usage: homeboy-dmc-provider.php resolve_task_standalone <task-url> <dmc-provider> <workspace-root>\n");
		exit(2);
	}
	try {
		$capture = $run_bounded_command(array( PHP_BINARY, $provider, 'task', $workspace, $task_url ), HOMEBOY_DMC_TASK_MAX_DMC_STDOUT_BYTES, HOMEBOY_DMC_TASK_MAX_DMC_STDERR_BYTES);
	} catch (Throwable $error) {
		fwrite(STDERR, $error->getMessage() . "\n");
		exit(1);
	}
	if ( null !== $capture['failure'] ) {
		fwrite(STDERR, "DMC standalone task resolution exceeded its bounded execution or capture.\n");
		exit(1);
	}
	if ( 0 !== $capture['status'] ) {
		fwrite(STDERR, 'DMC standalone task resolution failed: ' . trim($capture['stderr']) . "\n");
		exit($capture['status'] > 0 && $capture['status'] < 256 ? $capture['status'] : 1);
	}
	try {
		$payload = $decode_json_output($capture['stdout']);
	} catch (Throwable $error) {
		fwrite(STDERR, "DMC standalone task resolution returned invalid JSON.\n");
		exit(1);
	}
	$candidates = is_array($payload) ? ( $payload['candidates'] ?? null ) : null;
	if (
		! is_array($payload) || 'datamachine-code/worktree-task-resolution/v1' !== ( $payload['schema'] ?? null )
		|| 'complete' !== ( $payload['status'] ?? null ) || $task_url !== $canonical_task_url((string) ( $payload['task_url'] ?? '' ))
		|| ! is_array($candidates) || ! array_is_list($candidates) || ! is_int($payload['total'] ?? null)
		|| $payload['total'] !== count($candidates) || count($candidates) > HOMEBOY_DMC_TASK_MAX_CANDIDATES
	) {
		fwrite(STDERR, "DMC standalone task resolution returned an incomplete contract.\n");
		exit(1);
	}
	$result = array();
	foreach ( $candidates as $candidate ) {
		$safety = is_array($candidate) && is_array($candidate['safety'] ?? null) ? $candidate['safety'] : null;
		if (
			! is_array($candidate) || ! is_string($candidate['handle'] ?? null) || '' === $candidate['handle']
			|| ! is_string($candidate['path'] ?? null) || '' === $candidate['path']
			|| ! is_string($candidate['branch'] ?? null) || '' === $candidate['branch']
			|| $task_url !== $canonical_task_url((string) ( $candidate['task_url'] ?? '' ))
			|| ! is_array($safety) || ! is_bool($safety['dirty'] ?? null) || ! is_bool($safety['unpushed'] ?? null) || ! is_bool($safety['primary'] ?? null)
		) {
			fwrite(STDERR, "DMC standalone task resolution returned an incomplete or mismatched candidate.\n");
			exit(1);
		}
		foreach ( array( 'handle', 'path', 'branch', 'task_url' ) as $field ) {
			if ( strlen($candidate[ $field ]) > HOMEBOY_DMC_TASK_MAX_FIELD_BYTES ) {
				fwrite(STDERR, "DMC standalone task resolution field exceeds its bounded limit.\n");
				exit(1);
			}
		}
		$result[] = array(
			'handle'   => $candidate['handle'],
			'path'     => $candidate['path'],
			'branch'   => $candidate['branch'],
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
		fwrite(STDERR, "DMC standalone task resolution exceeded its bounded output.\n");
		exit(1);
	}
	fwrite(STDOUT, $serialized . "\n");
	exit(0);
}

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
	if ( null !== $capture['failure'] ) {
		$message = 'timeout' === $capture['failure'] ? 'DMC task worktree execution exceeded the adapter budget.' : ( 'session' === $capture['failure'] ? 'Could not isolate the DMC task worktree lookup session.' : 'DMC task worktree execution exceeded its bounded ' . $capture['failure'] . ' capture.' );
		fwrite(STDERR, $message . "\n");
		exit(1);
	}
	$stdout = $capture['stdout'];
	$stderr = $capture['stderr'];
	$status = $capture['status'];
	if ( 0 !== $status ) {
		try {
			$overflow = $decode_json_output($stdout);
		} catch (Throwable $error) {
			$overflow = null;
		}
		if ( is_array($overflow) && 'worktree_task_candidates_overflow' === ( $overflow['error']['code'] ?? $overflow['code'] ?? null ) ) {
			fwrite(STDERR, "DMC task worktree execution exceeded its complete candidate bound.\n");
		} else {
			fwrite(STDERR, 'DMC task worktree execution failed: ' . trim($stderr) . "\n");
		}
		exit($status > 0 && $status < 256 ? $status : 1);
	}
	try {
		$rows = $decode_json_output($stdout);
	} catch (Throwable $error) {
		fwrite(STDERR, 'DMC task worktree projection returned invalid JSON: ' . $error->getMessage() . "\n");
		exit(1);
	}
	if ( ! is_array($rows) || true !== ($rows['success'] ?? null) || ! is_array($rows['worktrees'] ?? null) || ! array_is_list($rows['worktrees']) || ! is_int($rows['total'] ?? null) || ! is_int($rows['returned'] ?? null) || null !== ($rows['next_cursor'] ?? null) || $rows['total'] !== $rows['returned'] || $rows['returned'] !== count($rows['worktrees']) ) {
		fwrite(STDERR, "DMC task worktree projection did not return one complete bounded page.\n");
		exit(1);
	}
	$rows = $rows['worktrees'];
	if ( count($rows) > HOMEBOY_DMC_TASK_MAX_CANDIDATES ) {
		fwrite(STDERR, "DMC task worktree projection exceeded its complete candidate bound.\n");
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
				fwrite(STDERR, "DMC task worktree projection returned an incomplete or mismatched task candidate.\n");
			exit(1);
		}
		if ( strlen($row['handle']) > HOMEBOY_DMC_TASK_MAX_FIELD_BYTES || strlen($row['path']) > HOMEBOY_DMC_TASK_MAX_FIELD_BYTES || strlen($row['branch']) > HOMEBOY_DMC_TASK_MAX_FIELD_BYTES || strlen($task_url) > HOMEBOY_DMC_TASK_MAX_FIELD_BYTES ) {
			fwrite(STDERR, "DMC task worktree projection field exceeds its bounded limit.\n");
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
		fwrite(STDERR, "DMC task worktree projection exceeds its bounded output.\n");
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
		$plan = $decode_json_output($stdout);
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

$run_provider = static function ( string $provider_operation, string $provider_value, string $provider_base = '' ) use ( $provider, $workspace, $decode_json_output ): array {
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
	$payload = $decode_json_output($stdout);
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
} elseif ( 'converge' === $operation && 'datamachine-code/worktree-convergence/v1' === ( $payload['schema'] ?? null ) && 'refused' === ( $payload['status'] ?? null ) && $value === ( $payload['identity_token'] ?? null ) && $base === ( $payload['base_sha'] ?? null ) && is_string($payload['code'] ?? null) && '' !== $payload['code'] ) {
	fwrite(STDERR, json_encode(array(
		'schema'         => 'homeboy/worktree-provider-convergence-refusal/v1',
		'identity_token' => $value,
		'base_sha'       => $base,
		'code'           => $payload['code'],
		'message'        => 'DMC refused worktree convergence: ' . $payload['code'],
	), JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n");
	exit(1);
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
		$task_url = $canonical_task_url((string) ( $payload['task_url'] ?? '' ));
		if (
			( '' === $task_url && ! str_starts_with($value, '/') )
			|| ! is_string($payload['handle'] ?? null) || '' === $payload['handle']
			|| ! is_string($payload['path'] ?? null) || '' === $payload['path']
			|| ! is_string($payload['branch'] ?? null) || '' === $payload['branch']
		) {
			fwrite(STDERR, "DMC standalone identity does not provide tracker ownership.\n");
			exit(1);
		}
		$result = array(
			array(
				'handle'  => $payload['handle'] ?? '',
				'path'    => $payload['path'] ?? '',
				'branch'  => $payload['branch'] ?? '',
				'task_url' => '' === $task_url ? null : $task_url,
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
