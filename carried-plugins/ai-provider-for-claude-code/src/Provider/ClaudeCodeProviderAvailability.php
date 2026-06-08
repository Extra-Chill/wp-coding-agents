<?php

declare(strict_types=1);

namespace ExtraChill\ClaudeCodeAiProvider\Provider;

use WordPress\AiClient\Providers\Contracts\ProviderAvailabilityInterface;

/**
 * Availability checker for the Claude Code provider.
 */
class ClaudeCodeProviderAvailability implements ProviderAvailabilityInterface
{
    /**
     * @var ClaudeCodeTokenStore Token store.
     */
    private ClaudeCodeTokenStore $tokenStore;

    /**
     * Constructor.
     *
     * @param ClaudeCodeTokenStore $tokenStore Token store.
     */
    public function __construct(ClaudeCodeTokenStore $tokenStore)
    {
        $this->tokenStore = $tokenStore;
    }

    /**
     * {@inheritDoc}
     */
    public function isConfigured(): bool
    {
        return $this->tokenStore->hasRefreshToken();
    }
}
