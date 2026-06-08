<?php

declare(strict_types=1);

namespace ExtraChill\ClaudeCodeAiProvider\Provider;

/**
 * Stores Claude Code OAuth tokens.
 *
 * @phpstan-type ClaudeCodeTokens array{access_token?: string, refresh_token?: string, expires_at?: int}
 */
class ClaudeCodeTokenStore
{
    private const OPTION_NAME = 'ai_provider_claude_code_oauth_tokens';

    /**
     * @return ClaudeCodeTokens Token data.
     */
    public function getTokens(): array
    {
        $tokens = [];
        if (function_exists('get_option')) {
            $tokens = get_option(self::OPTION_NAME, []);
        }

        if (!is_array($tokens)) {
            $tokens = [];
        }

        /** @var array<string, mixed> $tokenData */
        $tokenData = $tokens;
        $tokens = $this->addEnvironmentTokens($tokenData);
        $tokens = $this->addConstantTokens($tokens);

        if (function_exists('apply_filters')) {
            $tokens = apply_filters('ai_provider_claude_code_oauth_tokens', $tokens);
        }

        if (!is_array($tokens)) {
            return [];
        }

        /** @var array<string, mixed> $tokens */
        return $this->sanitizeTokens($tokens);
    }

    /**
     * @param array<string, mixed> $tokens Token data.
     */
    public function updateTokens(array $tokens): void
    {
        if (!function_exists('update_option')) {
            return;
        }

        update_option(self::OPTION_NAME, $this->sanitizeTokens($tokens), false);
    }

    public function hasRefreshToken(): bool
    {
        $tokens = $this->getTokens();
        return !empty($tokens['refresh_token']);
    }

    public function getAccessToken(): ?string
    {
        $tokens = $this->getTokens();
        $accessToken = $tokens['access_token'] ?? '';
        $expiresAt = $tokens['expires_at'] ?? 0;

        if ($accessToken === '' || $expiresAt <= time() + 60) {
            return null;
        }

        return $accessToken;
    }

    /**
     * @param array<string, mixed> $tokens Token data.
     * @return array<string, mixed> Token data.
     */
    private function addEnvironmentTokens(array $tokens): array
    {
        foreach ($this->tokenSourceMap() as $name => $tokenKey) {
            $value = getenv($name);
            if ($value !== false) {
                $tokens[$tokenKey] = $value;
            }
        }

        return $tokens;
    }

    /**
     * @param array<string, mixed> $tokens Token data.
     * @return array<string, mixed> Token data.
     */
    private function addConstantTokens(array $tokens): array
    {
        foreach ($this->tokenSourceMap() as $constantName => $tokenKey) {
            if (defined($constantName)) {
                $tokens[$tokenKey] = constant($constantName);
            }
        }

        return $tokens;
    }

    /**
     * @return array<string, string>
     */
    private function tokenSourceMap(): array
    {
        return [
            'AI_PROVIDER_CLAUDE_CODE_ACCESS_TOKEN' => 'access_token',
            'AI_PROVIDER_CLAUDE_CODE_REFRESH_TOKEN' => 'refresh_token',
            'AI_PROVIDER_CLAUDE_CODE_EXPIRES_AT' => 'expires_at',
        ];
    }

    /**
     * @param array<string, mixed> $tokens Raw token data.
     * @return ClaudeCodeTokens Sanitized token data.
     */
    private function sanitizeTokens(array $tokens): array
    {
        /** @var ClaudeCodeTokens $sanitized */
        $sanitized = [];
        foreach (['access_token', 'refresh_token'] as $key) {
            if (isset($tokens[$key]) && is_scalar($tokens[$key])) {
                $sanitized[$key] = trim((string) $tokens[$key]);
            }
        }

        if (isset($tokens['expires_at']) && is_numeric($tokens['expires_at'])) {
            $sanitized['expires_at'] = (int) $tokens['expires_at'];
        }

        return $sanitized;
    }
}
