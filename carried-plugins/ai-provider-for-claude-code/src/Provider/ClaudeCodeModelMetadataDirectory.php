<?php

declare(strict_types=1);

namespace ExtraChill\ClaudeCodeAiProvider\Provider;

use WordPress\AiClient\Common\Exception\InvalidArgumentException;
use WordPress\AiClient\Messages\Enums\ModalityEnum;
use WordPress\AiClient\Providers\Contracts\ModelMetadataDirectoryInterface;
use WordPress\AiClient\Providers\Models\DTO\ModelMetadata;
use WordPress\AiClient\Providers\Models\DTO\SupportedOption;
use WordPress\AiClient\Providers\Models\Enums\CapabilityEnum;
use WordPress\AiClient\Providers\Models\Enums\OptionEnum;

/**
 * Model metadata directory for Claude Code CLI models.
 */
class ClaudeCodeModelMetadataDirectory implements ModelMetadataDirectoryInterface
{
    /**
     * {@inheritDoc}
     */
    public function listModelMetadata(): array
    {
        return array_values($this->getModelMap());
    }

    /**
     * {@inheritDoc}
     */
    public function hasModelMetadata(string $modelId): bool
    {
        return isset($this->getModelMap()[$modelId]);
    }

    /**
     * {@inheritDoc}
     */
    public function getModelMetadata(string $modelId): ModelMetadata
    {
        $models = $this->getModelMap();
        if (!isset($models[$modelId])) {
            throw new InvalidArgumentException('No Claude Code model with the requested ID was found.');
        }

        return $models[$modelId];
    }

    /**
     * Gets the supported Claude Code model map.
     *
     * @return array<string, ModelMetadata> Model metadata keyed by ID.
     */
    private function getModelMap(): array
    {
        $options = [
            new SupportedOption(OptionEnum::systemInstruction()),
            new SupportedOption(OptionEnum::customOptions()),
            new SupportedOption(OptionEnum::inputModalities(), [[ModalityEnum::text()]]),
            new SupportedOption(OptionEnum::outputModalities(), [[ModalityEnum::text()]]),
        ];

        $models = [];
        foreach (['claude-code', 'sonnet', 'opus', 'haiku'] as $modelId) {
            $models[$modelId] = new ModelMetadata(
                $modelId,
                $modelId,
                [CapabilityEnum::textGeneration(), CapabilityEnum::chatHistory()],
                $options
            );
        }

        return $models;
    }
}
