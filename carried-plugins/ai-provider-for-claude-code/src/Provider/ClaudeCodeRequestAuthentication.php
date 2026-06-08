<?php

declare(strict_types=1);

namespace ExtraChill\ClaudeCodeAiProvider\Provider;

use WordPress\AiClient\Providers\Http\Contracts\RequestAuthenticationInterface;
use WordPress\AiClient\Providers\Http\DTO\Request;

/**
 * Authenticates requests as Claude Code OAuth traffic.
 */
class ClaudeCodeRequestAuthentication implements RequestAuthenticationInterface
{
    private const CLAUDE_CODE_VERSION = '2.1.75';
    private const ANTHROPIC_BETA = 'claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14';

    /**
     * @var ClaudeCodeTokenStore Token store.
     */
    private ClaudeCodeTokenStore $tokenStore;

    /**
     * @var ClaudeCodeOAuthClient OAuth client.
     */
    private ClaudeCodeOAuthClient $oauthClient;

    public function __construct(ClaudeCodeTokenStore $tokenStore, ClaudeCodeOAuthClient $oauthClient)
    {
        $this->tokenStore = $tokenStore;
        $this->oauthClient = $oauthClient;
    }

    /**
     * {@inheritDoc}
     */
    public function authenticateRequest(Request $request): Request
    {
        return $request
            ->withHeader('Accept', 'application/json')
            ->withHeader('Anthropic-Version', '2023-06-01')
            ->withHeader('Anthropic-Beta', self::ANTHROPIC_BETA)
            ->withHeader('Anthropic-Dangerous-Direct-Browser-Access', 'true')
            ->withHeader('Authorization', 'Bearer ' . $this->oauthClient->getAccessToken())
            ->withHeader('User-Agent', $this->userAgent())
            ->withHeader('X-App', 'cli');
    }

    /**
     * {@inheritDoc}
     */
    public static function getJsonSchema(): array
    {
        return [
            'type' => 'object',
            'properties' => [],
        ];
    }

    private function userAgent(): string
    {
        $userAgent = getenv('AI_PROVIDER_CLAUDE_CODE_USER_AGENT') ?: '';
        if (defined('AI_PROVIDER_CLAUDE_CODE_USER_AGENT')) {
            $userAgent = (string) constant('AI_PROVIDER_CLAUDE_CODE_USER_AGENT');
        }

        return $userAgent !== '' ? $userAgent : 'claude-cli/' . self::CLAUDE_CODE_VERSION;
    }
}
