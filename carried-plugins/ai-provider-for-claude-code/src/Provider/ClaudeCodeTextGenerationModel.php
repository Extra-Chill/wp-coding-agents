<?php

declare(strict_types=1);

namespace ExtraChill\ClaudeCodeAiProvider\Provider;

use WordPress\AiClient\Common\Exception\InvalidArgumentException;
use WordPress\AiClient\Messages\DTO\Message;
use WordPress\AiClient\Messages\DTO\MessagePart;
use WordPress\AiClient\Messages\DTO\ModelMessage;
use WordPress\AiClient\Messages\Enums\MessageRoleEnum;
use WordPress\AiClient\Providers\ApiBasedImplementation\AbstractApiBasedModel;
use WordPress\AiClient\Providers\Http\DTO\Request;
use WordPress\AiClient\Providers\Http\DTO\RequestOptions;
use WordPress\AiClient\Providers\Http\DTO\Response;
use WordPress\AiClient\Providers\Http\Enums\HttpMethodEnum;
use WordPress\AiClient\Providers\Http\Exception\ResponseException;
use WordPress\AiClient\Providers\Http\Util\ResponseUtil;
use WordPress\AiClient\Providers\Models\TextGeneration\Contracts\TextGenerationModelInterface;
use WordPress\AiClient\Results\DTO\Candidate;
use WordPress\AiClient\Results\DTO\GenerativeAiResult;
use WordPress\AiClient\Results\DTO\TokenUsage;
use WordPress\AiClient\Results\Enums\FinishReasonEnum;

/**
 * Text generation model for Claude Code using Anthropic Messages API.
 */
class ClaudeCodeTextGenerationModel extends AbstractApiBasedModel implements TextGenerationModelInterface
{
    private const CLAUDE_CODE_IDENTITY = "You are Claude Code, Anthropic's official CLI for Claude.";
    private const REQUEST_TIMEOUT_FLOOR = 300.0;
    private const CONNECT_TIMEOUT_FLOOR = 120.0;

    /**
     * {@inheritDoc}
     */
    public function generateTextResult(array $prompt): GenerativeAiResult
    {
        $request = new Request(
            HttpMethodEnum::POST(),
            ClaudeCodeProvider::url('messages'),
            ['Content-Type' => 'application/json'],
            $this->prepareGenerateTextParams($prompt),
            $this->getClaudeCodeRequestOptions()
        );

        $request = $this->getRequestAuthentication()->authenticateRequest($request);
        $response = $this->getHttpTransporter()->send($request);
        ResponseUtil::throwIfNotSuccessful($response);

        return $this->parseResponseToResult($response);
    }

    private function getClaudeCodeRequestOptions(): RequestOptions
    {
        $current = $this->getRequestOptions();
        $options = new RequestOptions();

        $timeout = $current?->getTimeout();
        $timeout = max($timeout ?? 0.0, self::REQUEST_TIMEOUT_FLOOR);
        $options->setTimeout($timeout);

        $connectTimeout = $current?->getConnectTimeout();
        $connectTimeoutFloor = min(self::CONNECT_TIMEOUT_FLOOR, $timeout);
        $options->setConnectTimeout(max($connectTimeout ?? 0.0, $connectTimeoutFloor));

        $maxRedirects = $current?->getMaxRedirects();
        if ($maxRedirects !== null) {
            $options->setMaxRedirects($maxRedirects);
        }

        return $options;
    }

    /**
     * Prepares the Anthropic Messages request payload.
     *
     * @param list<Message> $prompt Prompt messages.
     * @return array<string, mixed> Request payload.
     */
    private function prepareGenerateTextParams(array $prompt): array
    {
        $config = $this->getConfig();
        $system = [
            ['type' => 'text', 'text' => self::CLAUDE_CODE_IDENTITY],
        ];

        if ($config->getSystemInstruction()) {
            $system[] = ['type' => 'text', 'text' => $config->getSystemInstruction()];
        }

        $params = [
            'model' => $this->metadata()->getId(),
            'max_tokens' => $config->getMaxTokens() ?? 4096,
            'messages' => $this->prepareMessages($prompt),
            'system' => $system,
        ];

        $temperature = $config->getTemperature();
        if ($temperature !== null) {
            $params['temperature'] = $temperature;
        }

        $topP = $config->getTopP();
        if ($topP !== null) {
            $params['top_p'] = $topP;
        }

        if ($config->getOutputMimeType() === 'application/json' && $config->getOutputSchema()) {
            $params['tools'] = [
                [
                    'name' => 'response_schema',
                    'description' => 'Return a response matching the requested JSON schema.',
                    'input_schema' => $config->getOutputSchema(),
                ],
            ];
            $params['tool_choice'] = ['type' => 'tool', 'name' => 'response_schema'];
        }

        foreach ($config->getCustomOptions() as $key => $value) {
            if (isset($params[$key])) {
                throw new InvalidArgumentException(
                    sprintf('The custom option "%s" conflicts with an existing Claude Code request parameter.', $key)
                );
            }
            $params[$key] = $value;
        }

        return $params;
    }

    /**
     * Converts prompt messages to Anthropic Messages format.
     *
     * @param list<Message> $messages Prompt messages.
     * @return list<array<string, mixed>> Messages.
     */
    private function prepareMessages(array $messages): array
    {
        $output = [];
        foreach ($messages as $message) {
            $content = [];
            foreach ($message->getParts() as $part) {
                $content[] = ['type' => 'text', 'text' => $this->prepareMessagePartText($part)];
            }

            $output[] = [
                'role' => $this->roleToAnthropicRole($message->getRole()),
                'content' => $content,
            ];
        }

        return $output;
    }

    private function prepareMessagePartText(MessagePart $part): string
    {
        if ($part->getType()->isText()) {
            return (string) $part->getText();
        }

        $payload = ['type' => $part->getType()->value];
        if ($part->getType()->isFunctionCall() && $part->getFunctionCall()) {
            $payload['function_call'] = $part->getFunctionCall()->toArray();
        } elseif ($part->getType()->isFunctionResponse() && $part->getFunctionResponse()) {
            $payload['function_response'] = $part->getFunctionResponse()->toArray();
        } elseif ($part->getType()->isFile() && $part->getFile()) {
            $payload['file'] = $part->getFile()->toArray();
        }

        return $this->encodeJson($payload);
    }

    private function roleToAnthropicRole(MessageRoleEnum $role): string
    {
        return $role->isModel() ? 'assistant' : 'user';
    }

    private function parseResponseToResult(Response $response): GenerativeAiResult
    {
        $data = $response->getData();
        if (!is_array($data)) {
            $data = json_decode((string) $response->getBody(), true);
        }
        if (!is_array($data)) {
            throw ResponseException::fromMissingData('Claude Code', 'content');
        }

        $text = $this->extractText($data);
        if ($text === '') {
            throw ResponseException::fromMissingData('Claude Code', 'content.text');
        }

        $usage = isset($data['usage']) && is_array($data['usage']) ? $data['usage'] : [];
        $inputTokens = $this->getIntegerValue($usage['input_tokens'] ?? null);
        $outputTokens = $this->getIntegerValue($usage['output_tokens'] ?? null);

        return new GenerativeAiResult(
            isset($data['id']) && is_string($data['id']) ? $data['id'] : '',
            [new Candidate(new ModelMessage([new MessagePart($text)]), FinishReasonEnum::stop())],
            new TokenUsage($inputTokens, $outputTokens, $inputTokens + $outputTokens),
            $this->providerMetadata(),
            $this->metadata(),
            $data
        );
    }

    /**
     * @param array<string, mixed> $data Response data.
     */
    private function extractText(array $data): string
    {
        $parts = [];
        if (!isset($data['content']) || !is_array($data['content'])) {
            return '';
        }

        foreach ($data['content'] as $part) {
            if (!is_array($part)) {
                continue;
            }
            if (($part['type'] ?? '') === 'text' && isset($part['text']) && is_string($part['text'])) {
                $parts[] = $part['text'];
            } elseif (($part['type'] ?? '') === 'tool_use' && isset($part['input'])) {
                $parts[] = $this->encodeJson($part['input']);
            }
        }

        return implode("\n", array_filter($parts, 'is_string'));
    }

    /**
     * @param mixed $value Raw value.
     */
    private function encodeJson($value): string
    {
        $encoded = function_exists('wp_json_encode') ? wp_json_encode($value) : json_encode($value);
        return is_string($encoded) ? $encoded : '';
    }

    /**
     * @param mixed $value Raw value.
     */
    private function getIntegerValue($value): int
    {
        return is_numeric($value) ? (int) $value : 0;
    }
}
