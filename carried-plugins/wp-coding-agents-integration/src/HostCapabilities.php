<?php
/**
 * Host capability probes used by WordPress-resident integrations.
 *
 * @package WpCodingAgents\Integration
 */

declare(strict_types=1);

namespace WpCodingAgents\Integration;

if (!defined('ABSPATH')) {
	exit;
}

final class HostCapabilities {
	/**
	 * @var array{ok: bool, reason: string, exec_available: bool, shell_exec_available: bool, proc_open_available: bool, output?: string, exit_code?: int|null}|null
	 */
	private static ?array $shell_diagnostic = null;

	public static function has_shell(): bool {
		return true === self::shell_diagnostic()['ok'];
	}

	/**
	 * The CLI transport requires a process API and a session-safe cleanup path.
	 */
	public static function can_execute_processes(): bool {
		return true === self::evaluate_process_capability(
			static fn(string $function_name): bool => function_exists($function_name),
			(string) ini_get('disable_functions'),
			static function (string $command): array {
				$output = array();
				$exit_code = null;
				// phpcs:ignore WordPress.PHP.DiscouragedPHPFunctions.system_calls_exec -- Capability probe.
				exec($command, $output, $exit_code);
				return array('output' => $output, 'exit_code' => $exit_code);
			},
			static fn(): bool => self::has_session_launcher()
		)['ok'];
	}

	/**
	 * Verify every PHP primitive the CLI transport invokes after claiming work.
	 *
	 * @param callable $function_exists      Receives a function name and returns its availability.
	 * @param callable $command_runner       Receives a command and returns output plus exit code.
	 * @param callable $has_session_launcher Returns whether a usable setsid launcher exists.
	 * @return array{ok: bool, reason: string, exec_available: bool, shell_exec_available: bool, proc_open_available: bool, output?: string, exit_code?: int|null}
	 */
	public static function evaluate_process_capability(callable $function_exists, string $disabled_functions, callable $command_runner, callable $has_session_launcher): array {
		$diagnostic = self::evaluate_shell_capability($function_exists, $disabled_functions, $command_runner);
		if (true !== $diagnostic['ok']) {
			return $diagnostic;
		}

		$disabled = array_filter(array_map('trim', explode(',', $disabled_functions)));
		foreach (array('proc_open', 'proc_get_status', 'proc_close', 'proc_terminate', 'posix_kill') as $function_name) {
			if (!self::function_available($function_name, $function_exists, $disabled)) {
				return array_merge($diagnostic, array(
					'ok' => false,
					'reason' => $function_exists($function_name) ? $function_name . '_disabled' : $function_name . '_missing',
				));
			}
		}

		if (!$has_session_launcher()) {
			return array_merge($diagnostic, array('ok' => false, 'reason' => 'setsid_missing'));
		}

		return $diagnostic;
	}

	/**
	 * @return array{ok: bool, reason: string, exec_available: bool, shell_exec_available: bool, proc_open_available: bool, output?: string, exit_code?: int|null}
	 */
	public static function shell_diagnostic(): array {
		if (null === self::$shell_diagnostic) {
			self::$shell_diagnostic = self::evaluate_shell_capability(
				static fn(string $function_name): bool => function_exists($function_name),
				(string) ini_get('disable_functions'),
				static function (string $command): array {
					$output = array();
					$exit_code = null;
					// phpcs:ignore WordPress.PHP.DiscouragedPHPFunctions.system_calls_exec -- Capability probe.
					exec($command, $output, $exit_code);
					return array('output' => $output, 'exit_code' => $exit_code);
				}
			);
		}

		return self::$shell_diagnostic;
	}

	/**
	 * @param callable $function_exists Receives a function name and returns its availability.
	 * @param callable $command_runner  Receives a command and returns output plus exit code.
	 * @return array{ok: bool, reason: string, exec_available: bool, shell_exec_available: bool, proc_open_available: bool, output?: string, exit_code?: int|null}
	 */
	public static function evaluate_shell_capability(callable $function_exists, string $disabled_functions, callable $command_runner): array {
		$disabled = array_filter(array_map('trim', explode(',', $disabled_functions)));
		$base = array(
			'exec_available' => self::function_available('exec', $function_exists, $disabled),
			'shell_exec_available' => self::function_available('shell_exec', $function_exists, $disabled),
			'proc_open_available' => self::function_available('proc_open', $function_exists, $disabled),
		);

		foreach (array('exec', 'shell_exec') as $function_name) {
			$key = $function_name . '_available';
			if (!$base[$key]) {
				$reason = $function_exists($function_name) ? $function_name . '_disabled' : $function_name . '_missing';
				return array_merge($base, array('ok' => false, 'reason' => $reason));
			}
		}

		$marker = '__wp_coding_agents_shell_ok__';
		$result = $command_runner('printf ' . escapeshellarg($marker) . ' 2>&1');
		$output = trim(implode("\n", array_map('strval', $result['output'])));
		$exit_code = $result['exit_code'];
		if (0 !== $exit_code || $marker !== $output) {
			return array_merge($base, array('ok' => false, 'reason' => 'probe_failed', 'output' => $output, 'exit_code' => $exit_code));
		}

		return array_merge($base, array('ok' => true, 'reason' => 'ok', 'output' => $output, 'exit_code' => $exit_code));
	}

	public static function has_writable_content_directory(): bool {
		// phpcs:ignore WordPress.WP.AlternativeFunctions.file_system_operations_is_writable -- Capability probe.
		return defined('WP_CONTENT_DIR') && is_writable(WP_CONTENT_DIR);
	}

	private static function has_session_launcher(): bool {
		$candidates = array('/usr/bin/setsid', '/bin/setsid');
		$path = getenv('PATH');
		if (is_string($path)) {
			foreach (explode(PATH_SEPARATOR, $path) as $directory) {
				if ('' !== $directory) {
					$candidates[] = rtrim($directory, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . 'setsid';
				}
			}
		}

		foreach (array_unique($candidates) as $candidate) {
			if (is_file($candidate) && is_executable($candidate)) {
				return true;
			}
		}

		return false;
	}

	/**
	 * @param string[] $disabled
	 */
	private static function function_available(string $function_name, callable $function_exists, array $disabled): bool {
		return $function_exists($function_name) && !in_array($function_name, $disabled, true);
	}
}
