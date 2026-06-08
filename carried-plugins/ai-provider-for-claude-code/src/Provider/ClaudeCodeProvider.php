<?php

declare(strict_types=1);

namespace ExtraChill\ClaudeCodeAiProvider\Provider;

use WordPress\AiClient\Common\Exception\RuntimeException;
use WordPress\AiClient\Providers\ApiBasedImplementation\AbstractApiProvider;
use WordPress\AiClient\Providers\Contracts\ModelMetadataDirectoryInterface;
use WordPress\AiClient\Providers\Contracts\ProviderAvailabilityInterface;
use WordPress\AiClient\Providers\DTO\ProviderMetadata;
use WordPress\AiClient\Providers\Enums\ProviderTypeEnum;
use WordPress\AiClient\Providers\Http\Enums\RequestAuthenticationMethod;
use WordPress\AiClient\Providers\Models\Contracts\ModelInterface;
use WordPress\AiClient\Providers\Models\DTO\ModelMetadata;

/**
 * Provider for Claude Code subscription-backed access.
 */
class ClaudeCodeProvider extends AbstractApiProvider
{
    /**
     * {@inheritDoc}
     */
    protected static function baseUrl(): string
    {
        return 'https://api.anthropic.com/v1';
    }

    /**
     * {@inheritDoc}
     */
    protected static function createModel(
        ModelMetadata $modelMetadata,
        ProviderMetadata $providerMetadata
    ): ModelInterface {
        foreach ($modelMetadata->getSupportedCapabilities() as $capability) {
            if ($capability->isTextGeneration()) {
                return new ClaudeCodeTextGenerationModel($modelMetadata, $providerMetadata);
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
            ProviderTypeEnum::cloud(),
            'https://docs.anthropic.com/en/docs/claude-code',
            RequestAuthenticationMethod::apiKey(),
            'Claude Code subscription-backed access using Claude OAuth credentials.'
        );
    }

    /**
     * {@inheritDoc}
     */
    protected static function createProviderAvailability(): ProviderAvailabilityInterface
    {
        return new ClaudeCodeProviderAvailability(new ClaudeCodeTokenStore());
    }

    /**
     * {@inheritDoc}
     */
    protected static function createModelMetadataDirectory(): ModelMetadataDirectoryInterface
    {
        return new ClaudeCodeModelMetadataDirectory();
    }
}
