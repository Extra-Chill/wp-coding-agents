<?php

declare(strict_types=1);

namespace ExtraChill\ClaudeCodeAiProvider\Provider;

use ExtraChill\ClaudeCodeAiProvider\Runtime\ClaudeCodeProcess;
use WordPress\AiClient\Common\Exception\InvalidArgumentException;
use WordPress\AiClient\Messages\DTO\Message;
use WordPress\AiClient\Messages\DTO\MessagePart;
use WordPress\AiClient\Messages\DTO\ModelMessage;
use WordPress\AiClient\Providers\DTO\ProviderMetadata;
use WordPress\AiClient\Providers\Models\Contracts\ModelInterface;
use WordPress\AiClient\Providers\Models\DTO\ModelConfig;
use WordPress\AiClient\Providers\Models\DTO\ModelMetadata;
use WordPress\AiClient\Providers\Models\TextGeneration\Contracts\TextGenerationModelInterface;
use WordPress\AiClient\Results\DTO\Candidate;
use WordPress\AiClient\Results\DTO\GenerativeAiResult;
use WordPress\AiClient\Results\DTO\TokenUsage;
use WordPress\AiClient\Results\Enums\FinishReasonEnum;

/**
 * Text generation model backed by `claude -p`.
 */
class ClaudeCodeTextGenerationModel implements ModelInterface, TextGenerationModelInterface
{
    /**
     * @var ModelMetadata Model metadata.
     */
    private ModelMetadata $metadata;

    /**
     * @var ProviderMetadata Provider metadata.
     */
    private ProviderMetadata $providerMetadata;

    /**
     * @var ModelConfig Model config.
     */
    private ModelConfig $config;

    /**
     * @var ClaudeCodeProcess Claude Code process runner.
     */
    private ClaudeCodeProcess $process;

    /**
     * Constructor.
     *
     * @param ModelMetadata     $metadata         Model metadata.
     * @param ProviderMetadata  $providerMetadata Provider metadata.
     * @param ClaudeCodeProcess $process          Claude Code process runner.
     */
    public function __construct(
        ModelMetadata $metadata,
        ProviderMetadata $providerMetadata,
        ClaudeCodeProcess $process
    ) {
        $this->metadata = $metadata;
        $this->providerMetadata = $providerMetadata;
        $this->process = $process;
        $this->config = ModelConfig::fromArray([]);
    }

    /**
     * {@inheritDoc}
     */
    public function metadata(): ModelMetadata
    {
        return $this->metadata;
    }

    /**
     * {@inheritDoc}
     */
    public function providerMetadata(): ProviderMetadata
    {
        return $this->providerMetadata;
    }

    /**
     * {@inheritDoc}
     */
    public function setConfig(ModelConfig $config): void
    {
        $this->config = $config;
    }

    /**
     * {@inheritDoc}
     */
    public function getConfig(): ModelConfig
    {
        return $this->config;
    }

    /**
     * {@inheritDoc}
     */
    public function generateTextResult(array $prompt): GenerativeAiResult
    {
        $customOptions = $this->config->getCustomOptions();
        $result = $this->process->run(
            $this->preparePrompt($prompt),
            $this->metadata->getId(),
            $customOptions
        );

        return new GenerativeAiResult(
            $result['id'],
            [new Candidate(new ModelMessage([new MessagePart($result['text'])]), FinishReasonEnum::stop())],
            new TokenUsage(0, 0, 0),
            $this->providerMetadata,
            $this->metadata,
            [
                'command' => 'claude-code',
                'exit_code' => $result['exit_code'],
            ]
        );
    }

    /**
     * Converts WP AI Client messages to a Claude Code prompt string.
     *
     * @param list<Message> $messages Prompt messages.
     * @return string Prompt string.
     */
    private function preparePrompt(array $messages): string
    {
        $chunks = [];
        $systemInstruction = $this->config->getSystemInstruction();
        if ($systemInstruction) {
            $chunks[] = "System:\n" . $systemInstruction;
        }

        foreach ($messages as $message) {
            $parts = [];
            foreach ($message->getParts() as $part) {
                if (!$part->getType()->isText()) {
                    throw new InvalidArgumentException(
                        'Claude Code text generation currently supports text message parts only.'
                    );
                }
                $parts[] = $part->getText();
            }

            $role = $message->getRole()->isModel() ? 'Assistant' : 'User';
            $chunks[] = $role . ":\n" . implode("\n", $parts);
        }

        return implode("\n\n", $chunks);
    }
}
