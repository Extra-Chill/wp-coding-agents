<?php

declare(strict_types=1);

namespace ExtraChill\ClaudeCodeAiProvider\Provider;

use RuntimeException;

/**
 * Refreshes Claude Code OAuth access tokens.
 */
class ClaudeCodeOAuthClient
{
    private const TOKEN_URL = 'https://platform.claude.com/v1/oauth/token';
    private const CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';

    /**
     * @var ClaudeCodeTokenStore Token store.
     */
    private ClaudeCodeTokenStore $tokenStore;

    public function __construct(ClaudeCodeTokenStore $tokenStore)
    {
        $this->tokenStore = $tokenStore;
    }

    public function getAccessToken(): string
    {
        $accessToken = $this->tokenStore->getAccessToken();
        if ($accessToken !== null) {
            return $accessToken;
        }

        $tokens = $this->tokenStore->getTokens();
        $refreshToken = $tokens['refresh_token'] ?? '';
        if ($refreshToken === '') {
            throw new RuntimeException('Claude Code OAuth refresh token is not configured.');
        }

        $data = $this->refreshAccessToken($refreshToken);
        if (empty($data['access_token']) || !is_scalar($data['access_token'])) {
            throw new RuntimeException('Claude Code OAuth refresh returned an invalid response.');
        }

        $updated = array_merge(
            $tokens,
            [
                'access_token' => (string) $data['access_token'],
                'expires_at' => time() + $this->getIntegerValue($data['expires_in'] ?? null, 3600),
            ]
        );

        if (!empty($data['refresh_token']) && is_scalar($data['refresh_token'])) {
            $updated['refresh_token'] = (string) $data['refresh_token'];
        }

        $this->tokenStore->updateTokens($updated);
        return (string) $data['access_token'];
    }

    /**
     * @return array<string, mixed>
     */
    private function refreshAccessToken(string $refreshToken): array
    {
        $body = [
            'grant_type' => 'refresh_token',
            'client_id' => self::CLIENT_ID,
            'refresh_token' => $refreshToken,
        ];

        if (function_exists('wp_remote_post')) {
            return $this->refreshAccessTokenWithWordPress($body);
        }

        $context = stream_context_create(
            [
                'http' => [
                    'method' => 'POST',
                    'header' => "Content-Type: application/json\r\n",
                    'content' => json_encode($body),
                    'ignore_errors' => true,
                    'timeout' => 20,
                ],
            ]
        );
        $responseBody = file_get_contents(self::TOKEN_URL, false, $context);
        if ($responseBody === false) {
            throw new RuntimeException('Claude Code OAuth refresh failed.');
        }

        $data = json_decode($responseBody, true);
        if (!is_array($data)) {
            throw new RuntimeException('Claude Code OAuth refresh returned an invalid response.');
        }

        /** @var array<string, mixed> $data */
        return $data;
    }

    /**
     * @param array<string, string> $body Request body.
     * @return array<string, mixed>
     */
    private function refreshAccessTokenWithWordPress(array $body): array
    {
        $wpRemotePost = 'wp_remote_post';
        // @phpstan-ignore-next-line WordPress HTTP API is available at runtime when function_exists() passes.
        $response = $wpRemotePost(self::TOKEN_URL, [
            'body' => wp_json_encode($body),
            'headers' => ['Content-Type' => 'application/json'],
            'timeout' => 20,
        ]);

        $isWpError = 'is_wp_error';
        // @phpstan-ignore-next-line WordPress error helper is available at runtime when function_exists() passes.
        if (function_exists('is_wp_error') && $isWpError($response)) {
            throw new RuntimeException('Claude Code OAuth refresh failed.');
        }

        $wpRemoteRetrieveResponseCode = 'wp_remote_retrieve_response_code';
        $rawStatusCode = 0;
        if (function_exists('wp_remote_retrieve_response_code')) {
            // @phpstan-ignore-next-line WordPress HTTP helper is available at runtime when function_exists() passes.
            $rawStatusCode = $wpRemoteRetrieveResponseCode($response);
        }
        $statusCode = is_numeric($rawStatusCode) ? (int) $rawStatusCode : 0;
        if ($statusCode < 200 || $statusCode >= 300) {
            throw new RuntimeException('Claude Code OAuth refresh failed.');
        }

        $wpRemoteRetrieveBody = 'wp_remote_retrieve_body';
        $rawResponseBody = '';
        if (function_exists('wp_remote_retrieve_body')) {
            // @phpstan-ignore-next-line WordPress HTTP helper is available at runtime when function_exists() passes.
            $rawResponseBody = $wpRemoteRetrieveBody($response);
        }
        $responseBody = is_scalar($rawResponseBody) ? (string) $rawResponseBody : '';
        $data = json_decode($responseBody, true);
        if (!is_array($data)) {
            throw new RuntimeException('Claude Code OAuth refresh returned an invalid response.');
        }

        /** @var array<string, mixed> $data */
        return $data;
    }

    /**
     * @param mixed $value Raw value.
     */
    private function getIntegerValue($value, int $fallback): int
    {
        return is_numeric($value) ? (int) $value : $fallback;
    }
}
