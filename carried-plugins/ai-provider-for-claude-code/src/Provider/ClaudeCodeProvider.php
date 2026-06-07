<?php

declare(strict_types=1);

namespace ExtraChill\ClaudeCodeAiProvider\Provider;

use ExtraChill\ClaudeCodeAiProvider\Runtime\ClaudeCodeProcess;
use WordPress\AiClient\Common\Exception\RuntimeException;
use WordPress\AiClient\Providers\AbstractProvider;
use WordPress\AiClient\Providers\Contracts\ModelMetadataDirectoryInterface;
use WordPress\AiClient\Providers\Contracts\ProviderAvailabilityInterface;
use WordPress\AiClient\Providers\DTO\ProviderMetadata;
use WordPress\AiClient\Providers\Enums\ProviderTypeEnum;
use WordPress\AiClient\Providers\Models\Contracts\ModelInterface;
use WordPress\AiClient\Providers\Models\DTO\ModelMetadata;

/**
 * Provider backed by the local Claude Code CLI session.
 */
class ClaudeCodeProvider extends AbstractProvider
{
    /**
     * {@inheritDoc}
     */
    protected static function createModel(
        ModelMetadata $modelMetadata,
        ProviderMetadata $providerMetadata
    ): ModelInterface {
        foreach ($modelMetadata->getSupportedCapabilities() as $capability) {
            if ($capability->isTextGeneration()) {
                return new ClaudeCodeTextGenerationModel(
                    $modelMetadata,
                    $providerMetadata,
                    new ClaudeCodeProcess()
                );
            }
        }

        throw new RuntimeException('Unsupported Claude Code model capabilities.');
    }

    /**
     * {@inheritDoc}
     */
    protected static function createProviderMetadata(): ProviderMetadata
    {
        return new ProviderMetadata(
            'claude-code',
            'Claude Code',
            ProviderTypeEnum::server(),
            'https://docs.anthropic.com/en/docs/claude-code',
            null,
            'Local Claude Code CLI access using the host or sandbox authenticated session.'
        );
    }

    /**
     * {@inheritDoc}
     */
    protected static function createProviderAvailability(): ProviderAvailabilityInterface
    {
        return new ClaudeCodeProviderAvailability(new ClaudeCodeProcess());
    }

    /**
     * {@inheritDoc}
     */
    protected static function createModelMetadataDirectory(): ModelMetadataDirectoryInterface
    {
        return new ClaudeCodeModelMetadataDirectory();
    }
}
