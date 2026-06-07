<?php

declare(strict_types=1);

namespace ExtraChill\ClaudeCodeAiProvider\Runtime;

use WordPress\AiClient\Common\Exception\RuntimeException;

/**
 * Runs the local Claude Code CLI for provider requests.
 */
class ClaudeCodeProcess
{
    private const DEFAULT_TIMEOUT = 600;

    /**
     * Checks whether the Claude Code binary is available.
     *
     * @return bool True when available.
     */
    public function isAvailable(): bool
    {
        $binary = $this->binary();
        if (strpos($binary, '/') !== false) {
            return is_executable($binary);
        }

        $command = 'command -v ' . escapeshellarg($binary) . ' >/dev/null 2>&1';
        $process = proc_open($command, [], $pipes);
        if (!is_resource($process)) {
            return false;
        }

        return proc_close($process) === 0;
    }

    /**
     * Runs Claude Code for a prompt.
     *
     * @param string              $prompt        Prompt text.
     * @param string              $modelId       Model ID.
     * @param array<string,mixed> $customOptions Custom model options.
     * @return array{id:string,text:string,exit_code:int}
     */
    public function run(string $prompt, string $modelId, array $customOptions = []): array
    {
        $timeout = $this->timeout($customOptions);
        $command = [
            $this->binary(),
            '-p',
            $prompt,
            '--output-format',
            'text',
        ];

        if ($modelId !== 'claude-code') {
            $command[] = '--model';
            $command[] = $modelId;
        }

        foreach ($this->extraArgs($customOptions) as $arg) {
            $command[] = $arg;
        }

        $descriptorSpec = [
            0 => ['pipe', 'r'],
            1 => ['pipe', 'w'],
            2 => ['pipe', 'w'],
        ];

        $pipes = [];
        $process = proc_open(
            $command,
            $descriptorSpec,
            $pipes,
            $this->cwd($customOptions),
            $this->env()
        );

        if (!is_resource($process)) {
            throw new RuntimeException('Could not start Claude Code process.');
        }

        fclose($pipes[0]);
        stream_set_blocking($pipes[1], false);
        stream_set_blocking($pipes[2], false);

        $stdout = '';
        $stderr = '';
        $started = time();
        $exitCode = null;

        while (true) {
            $stdout .= stream_get_contents($pipes[1]);
            $stderr .= stream_get_contents($pipes[2]);
            $status = proc_get_status($process);

            if (!$status['running']) {
                break;
            }

            if ((time() - $started) > $timeout) {
                proc_terminate($process);
                $exitCode = 124;
                break;
            }

            usleep(100000);
        }

        $stdout .= stream_get_contents($pipes[1]);
        $stderr .= stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        $closedExitCode = proc_close($process);
        if ($exitCode === null) {
            $exitCode = $closedExitCode;
        }

        if ($exitCode !== 0) {
            throw new RuntimeException(
                sprintf('Claude Code exited with status %d: %s', $exitCode, $this->truncate(trim($stderr)))
            );
        }

        $text = trim($stdout);
        if ($text === '') {
            throw new RuntimeException('Claude Code returned an empty response.');
        }

        return [
            'id' => 'claude-code-' . gmdate('YmdHis') . '-' . substr(sha1($text), 0, 12),
            'text' => $text,
            'exit_code' => $exitCode,
        ];
    }

    /**
     * Gets the Claude Code binary path/name.
     *
     * @return string Binary.
     */
    private function binary(): string
    {
        $binary = getenv('AI_PROVIDER_CLAUDE_CODE_BIN') ?: 'claude';

        if (defined('AI_PROVIDER_CLAUDE_CODE_BIN')) {
            $binary = (string) constant('AI_PROVIDER_CLAUDE_CODE_BIN');
        }

        if (function_exists('apply_filters')) {
            $binary = apply_filters('ai_provider_claude_code_bin', $binary);
        }

        return is_string($binary) && $binary !== '' ? $binary : 'claude';
    }

    /**
     * Gets the process working directory.
     *
     * @param array<string,mixed> $customOptions Custom model options.
     * @return string|null Working directory.
     */
    private function cwd(array $customOptions): ?string
    {
        if (isset($customOptions['cwd']) && is_string($customOptions['cwd']) && $customOptions['cwd'] !== '') {
            return $customOptions['cwd'];
        }

        if (defined('ABSPATH')) {
            return ABSPATH;
        }

        $cwd = getcwd();
        return $cwd !== false ? $cwd : null;
    }

    /**
     * Gets the process timeout in seconds.
     *
     * @param array<string,mixed> $customOptions Custom model options.
     * @return int Timeout.
     */
    private function timeout(array $customOptions): int
    {
        if (isset($customOptions['timeout']) && is_numeric($customOptions['timeout'])) {
            return max(1, (int) $customOptions['timeout']);
        }

        $timeout = getenv('AI_PROVIDER_CLAUDE_CODE_TIMEOUT');
        if ($timeout !== false && is_numeric($timeout)) {
            return max(1, (int) $timeout);
        }

        return self::DEFAULT_TIMEOUT;
    }

    /**
     * Gets additional CLI arguments.
     *
     * @param array<string,mixed> $customOptions Custom model options.
     * @return list<string> Extra args.
     */
    private function extraArgs(array $customOptions): array
    {
        if (!isset($customOptions['args']) || !is_array($customOptions['args'])) {
            return [];
        }

        $args = [];
        foreach ($customOptions['args'] as $arg) {
            if (is_scalar($arg) && (string) $arg !== '') {
                $args[] = (string) $arg;
            }
        }

        return $args;
    }

    /**
     * Gets process environment overrides.
     *
     * @return array<string,string>|null Environment.
     */
    private function env(): ?array
    {
        $env = null;
        if (function_exists('apply_filters')) {
            $filtered = apply_filters('ai_provider_claude_code_env', null);
            if (is_array($filtered)) {
                $env = [];
                foreach ($filtered as $key => $value) {
                    if (is_string($key) && is_scalar($value)) {
                        $env[$key] = (string) $value;
                    }
                }
            }
        }

        return $env;
    }

    /**
     * Truncates process errors before surfacing them.
     *
     * @param string $value Raw text.
     * @return string Truncated text.
     */
    private function truncate(string $value): string
    {
        if (strlen($value) <= 800) {
            return $value;
        }

        return substr($value, 0, 800) . '...';
    }
}
