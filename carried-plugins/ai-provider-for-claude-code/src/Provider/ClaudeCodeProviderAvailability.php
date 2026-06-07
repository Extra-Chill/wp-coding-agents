<?php

declare(strict_types=1);

namespace ExtraChill\ClaudeCodeAiProvider\Provider;

use ExtraChill\ClaudeCodeAiProvider\Runtime\ClaudeCodeProcess;
use WordPress\AiClient\Providers\Contracts\ProviderAvailabilityInterface;

/**
 * Availability checker for the local Claude Code provider.
 */
class ClaudeCodeProviderAvailability implements ProviderAvailabilityInterface
{
    /**
     * @var ClaudeCodeProcess Claude Code process runner.
     */
    private ClaudeCodeProcess $process;

    /**
     * Constructor.
     *
     * @param ClaudeCodeProcess $process Claude Code process runner.
     */
    public function __construct(ClaudeCodeProcess $process)
    {
        $this->process = $process;
    }

    /**
     * {@inheritDoc}
     */
    public function isConfigured(): bool
    {
        return $this->process->isAvailable();
    }
}
