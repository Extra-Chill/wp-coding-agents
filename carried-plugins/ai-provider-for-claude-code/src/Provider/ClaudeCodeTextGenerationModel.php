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
use WordPress\AiClient\Tools\DTO\FunctionCall;
use WordPress\AiClient\Tools\DTO\FunctionResponse;

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

        $functionDeclarations = $config->getFunctionDeclarations();
        if (is_array($functionDeclarations) && $functionDeclarations !== []) {
            // Declare the agent's tools to Anthropic so the model returns
            // structured `tool_use` blocks instead of improvising tool calls
            // as freeform text.
            $params['tools'] = $this->prepareToolsParam($functionDeclarations);
        } elseif ($config->getOutputMimeType() === 'application/json' && $config->getOutputSchema()) {
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
     * Prepares the Anthropic `tools` parameter from function declarations.
     *
     * @param list<\WordPress\AiClient\Tools\DTO\FunctionDeclaration> $functionDeclarations Declarations.
     * @return list<array<string, mixed>> Anthropic tool definitions.
     */
    private function prepareToolsParam(array $functionDeclarations): array
    {
        $tools = [];
        foreach ($functionDeclarations as $functionDeclaration) {
            $parameters = $functionDeclaration->getParameters();
            $tools[] = [
                'name' => $functionDeclaration->getName(),
                'description' => $functionDeclaration->getDescription(),
                'input_schema' => is_array($parameters) && $parameters !== []
                    ? $parameters
                    : ['type' => 'object', 'properties' => (object) []],
            ];
        }

        return $tools;
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
                $content[] = $this->prepareMessagePartContent($part);
            }

            $output[] = [
                'role' => $this->roleToAnthropicRole($message->getRole()),
                'content' => $content,
            ];
        }

        return $output;
    }

    /**
     * Converts a single message part to an Anthropic content block.
     *
     * @param MessagePart $part Message part.
     * @return array<string, mixed> Anthropic content block.
     */
    private function prepareMessagePartContent(MessagePart $part): array
    {
        if ($part->getType()->isText()) {
            return ['type' => 'text', 'text' => (string) $part->getText()];
        }

        if ($part->getType()->isFunctionCall() && $part->getFunctionCall()) {
            $functionCall = $part->getFunctionCall();
            $arguments = $functionCall->getArgs();

            return [
                'type' => 'tool_use',
                'id' => (string) ($functionCall->getId() ?? $functionCall->getName() ?? ''),
                'name' => (string) ($functionCall->getName() ?? ''),
                'input' => is_array($arguments) ? $arguments : (object) [],
            ];
        }

        if ($part->getType()->isFunctionResponse() && $part->getFunctionResponse()) {
            $functionResponse = $part->getFunctionResponse();
            $response = $functionResponse->getResponse();

            return [
                'type' => 'tool_result',
                'tool_use_id' => (string) ($functionResponse->getId() ?? $functionResponse->getName() ?? ''),
                'content' => is_string($response) ? $response : $this->encodeJson($response),
            ];
        }

        // Fallback for unsupported part types: serialize as text so context is preserved.
        $payload = ['type' => $part->getType()->value];
        if ($part->getType()->isFile() && $part->getFile()) {
            $payload['file'] = $part->getFile()->toArray();
        }

        return ['type' => 'text', 'text' => $this->encodeJson($payload)];
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

        $parts = $this->parseResponseParts($data);
        if ($parts === []) {
            throw ResponseException::fromMissingData('Claude Code', 'content');
        }

        $usage = isset($data['usage']) && is_array($data['usage']) ? $data['usage'] : [];
        $inputTokens = $this->getIntegerValue($usage['input_tokens'] ?? null);
        $outputTokens = $this->getIntegerValue($usage['output_tokens'] ?? null);

        return new GenerativeAiResult(
            isset($data['id']) && is_string($data['id']) ? $data['id'] : '',
            [new Candidate(new ModelMessage($parts), $this->mapFinishReason($data['stop_reason'] ?? null))],
            new TokenUsage($inputTokens, $outputTokens, $inputTokens + $outputTokens),
            $this->providerMetadata(),
            $this->metadata(),
            $data
        );
    }

    /**
     * Converts Anthropic response content blocks into message parts.
     *
     * @param array<string, mixed> $data Response data.
     * @return list<MessagePart> Message parts.
     */
    private function parseResponseParts(array $data): array
    {
        $parts = [];
        if (!isset($data['content']) || !is_array($data['content'])) {
            return $parts;
        }

        foreach ($data['content'] as $part) {
            if (!is_array($part)) {
                continue;
            }

            $type = $part['type'] ?? '';
            if ($type === 'text' && isset($part['text']) && is_string($part['text']) && $part['text'] !== '') {
                $parts[] = new MessagePart($part['text']);
            } elseif ($type === 'tool_use') {
                $name = isset($part['name']) && is_string($part['name']) ? $part['name'] : '';
                if ($name === '') {
                    continue;
                }
                $input = isset($part['input']) && is_array($part['input']) ? $part['input'] : [];
                $id = isset($part['id']) && is_string($part['id']) ? $part['id'] : null;
                $parts[] = new MessagePart(new FunctionCall($id, $name, $input));
            }
        }

        return $parts;
    }

    /**
     * Maps an Anthropic stop reason to a finish reason.
     *
     * @param mixed $stopReason Anthropic stop reason.
     */
    private function mapFinishReason($stopReason): FinishReasonEnum
    {
        if ($stopReason === 'tool_use') {
            return FinishReasonEnum::toolCalls();
        }
        if ($stopReason === 'max_tokens') {
            return FinishReasonEnum::length();
        }

        return FinishReasonEnum::stop();
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
