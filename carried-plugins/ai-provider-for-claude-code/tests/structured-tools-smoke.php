<?php

/**
 * Headless smoke test for Claude Code provider structured tool calling.
 *
 * Proves the provider declares agent tools to Anthropic as `tools` with an
 * `input_schema`, serializes FunctionCall/FunctionResponse parts as
 * `tool_use`/`tool_result`, and parses Anthropic `tool_use` response blocks
 * back into FunctionCall message parts.
 *
 * Requires the WordPress AI Client source to be available. Point at it with
 * the PHP_AI_CLIENT_SRC env var, or place php-ai-client as a sibling checkout.
 *
 * Run: php tests/structured-tools-smoke.php
 */

declare(strict_types=1);

namespace ExtraChill\ClaudeCodeAiProvider\Tests;

use ExtraChill\ClaudeCodeAiProvider\Provider\ClaudeCodeProvider;
use WordPress\AiClient\Messages\DTO\Message;
use WordPress\AiClient\Messages\DTO\MessagePart;
use WordPress\AiClient\Messages\DTO\ModelMessage;
use WordPress\AiClient\Messages\DTO\UserMessage;
use WordPress\AiClient\Messages\Enums\MessageRoleEnum;
use WordPress\AiClient\Providers\Http\Contracts\HttpTransporterInterface;
use WordPress\AiClient\Providers\Http\DTO\Request;
use WordPress\AiClient\Providers\Http\DTO\RequestOptions;
use WordPress\AiClient\Providers\Http\DTO\Response;
use WordPress\AiClient\Providers\Models\DTO\ModelConfig;
use WordPress\AiClient\Providers\ProviderRegistry;
use WordPress\AiClient\Tools\DTO\FunctionCall;
use WordPress\AiClient\Tools\DTO\FunctionDeclaration;
use WordPress\AiClient\Tools\DTO\FunctionResponse;

$pluginDir = dirname(__DIR__);

$aiClientSrc = getenv('PHP_AI_CLIENT_SRC');
if (false === $aiClientSrc || '' === $aiClientSrc) {
    foreach (
        [
            dirname($pluginDir, 4) . '/php-ai-client/src',
            dirname($pluginDir, 5) . '/php-ai-client/src',
            getenv('HOME') . '/Developer/php-ai-client/src',
        ] as $candidate
    ) {
        if (is_string($candidate) && is_dir($candidate)) {
            $aiClientSrc = $candidate;
            break;
        }
    }
}

if (!is_string($aiClientSrc) || !is_dir($aiClientSrc)) {
    fwrite(STDERR, "SKIP: WordPress AI Client source not found. Set PHP_AI_CLIENT_SRC.\n");
    exit(0);
}

$polyfills = $aiClientSrc . '/polyfills.php';
if (is_file($polyfills)) {
    require_once $polyfills;
}

spl_autoload_register(static function (string $class) use ($aiClientSrc): void {
    $prefix = 'WordPress\\AiClient\\';
    $len = strlen($prefix);
    if (strncmp($class, $prefix, $len) !== 0) {
        return;
    }
    $relative = substr($class, $len);
    $file = $aiClientSrc . '/' . str_replace('\\', '/', $relative) . '.php';
    if (is_file($file)) {
        require $file;
    }
});

require_once $pluginDir . '/src/autoload.php';

$failures = 0;
$passes = 0;
$check = static function (bool $condition, string $message) use (&$failures, &$passes): void {
    if ($condition) {
        ++$passes;
        echo "PASS: {$message}\n";
        return;
    }
    ++$failures;
    echo "FAIL: {$message}\n";
};

// Capture the outgoing request and return a canned tool_use response.
$capturedRequests = [];
$registry = new ProviderRegistry();
$registry->setHttpTransporter(
    new class ($capturedRequests) implements HttpTransporterInterface {
        /** @var array<int, Request> */
        private array $captured;

        /**
         * @param array<int, Request> $captured
         */
        public function __construct(array &$captured)
        {
            $this->captured = &$captured;
        }

        public function send(Request $request, ?RequestOptions $options = null): Response
        {
            $this->captured[] = $request;

            $body = json_encode(
                [
                    'id' => 'msg_test',
                    'type' => 'message',
                    'role' => 'assistant',
                    'stop_reason' => 'tool_use',
                    'content' => [
                        ['type' => 'text', 'text' => 'Writing the file now.'],
                        [
                            'type' => 'tool_use',
                            'id' => 'toolu_123',
                            'name' => 'workspace_write',
                            'input' => ['path' => 'X.md', 'content' => '# hi'],
                        ],
                    ],
                    'usage' => ['input_tokens' => 5, 'output_tokens' => 7],
                ]
            );

            return new Response(200, ['Content-Type' => 'application/json'], (string) $body);
        }
    }
);

putenv('AI_PROVIDER_CLAUDE_CODE_ACCESS_TOKEN=test-access-token');
putenv('AI_PROVIDER_CLAUDE_CODE_REFRESH_TOKEN=test-refresh-token');
putenv('AI_PROVIDER_CLAUDE_CODE_EXPIRES_AT=' . (time() + 3600));

$registry->registerProvider(ClaudeCodeProvider::class);
$registry->setProviderRequestAuthentication(
    ClaudeCodeProvider::class,
    new \ExtraChill\ClaudeCodeAiProvider\Provider\ClaudeCodeRequestAuthentication(
        new \ExtraChill\ClaudeCodeAiProvider\Provider\ClaudeCodeTokenStore(),
        new \ExtraChill\ClaudeCodeAiProvider\Provider\ClaudeCodeOAuthClient(
            new \ExtraChill\ClaudeCodeAiProvider\Provider\ClaudeCodeTokenStore()
        )
    )
);

$check($registry->isProviderConfigured('claude-code') === true, 'provider is configured with OAuth tokens');

$model = $registry->getProviderModel('claude-code', 'claude-opus-4-8');

$config = ModelConfig::fromArray([]);
$config->setFunctionDeclarations([
    new FunctionDeclaration(
        'workspace_write',
        'Write a file to the workspace.',
        [
            'type' => 'object',
            'properties' => [
                'path' => ['type' => 'string'],
                'content' => ['type' => 'string'],
            ],
            'required' => ['path', 'content'],
        ]
    ),
]);
$model->setConfig($config);

// Prompt includes a prior tool call + response to exercise tool_use/tool_result serialization.
$prompt = [
    new UserMessage([new MessagePart('create X.md')]),
    new ModelMessage([new MessagePart(new FunctionCall('toolu_prev', 'workspace_ls', ['path' => '.']))]),
    new Message(
        MessageRoleEnum::user(),
        [new MessagePart(new FunctionResponse('toolu_prev', 'workspace_ls', ['files' => ['README.md']]))]
    ),
];

$result = $model->generateTextResult($prompt);

// --- Assert the outgoing request declared structured tools ---
$check(count($capturedRequests) === 1, 'exactly one request was dispatched');
$requestData = $capturedRequests[0]->getData();
$check(is_array($requestData), 'request body is an array');

$tools = $requestData['tools'] ?? null;
$check(is_array($tools) && count($tools) === 1, 'request declares one tool');
$check(($tools[0]['name'] ?? null) === 'workspace_write', 'tool name is forwarded');
$check(($tools[0]['description'] ?? null) === 'Write a file to the workspace.', 'tool description is forwarded');
$check(
    isset($tools[0]['input_schema']['properties']['path']),
    'tool parameters are forwarded as input_schema'
);

// --- Assert FunctionCall/FunctionResponse parts became tool_use/tool_result blocks ---
$messages = $requestData['messages'] ?? [];
$blocks = [];
foreach ($messages as $message) {
    foreach (($message['content'] ?? []) as $contentBlock) {
        $blocks[] = $contentBlock['type'] ?? '';
    }
}
$check(in_array('tool_use', $blocks, true), 'prior FunctionCall serialized as tool_use block');
$check(in_array('tool_result', $blocks, true), 'prior FunctionResponse serialized as tool_result block');

// --- Assert the response tool_use parsed into a FunctionCall message part ---
$candidates = $result->getCandidates();
$check(count($candidates) === 1, 'result has one candidate');
$parts = $candidates[0]->getMessage()->getParts();
$functionCallPart = null;
foreach ($parts as $part) {
    if ($part->getType()->isFunctionCall()) {
        $functionCallPart = $part;
        break;
    }
}
$check($functionCallPart !== null, 'response tool_use parsed into a FunctionCall part');
if ($functionCallPart !== null) {
    $functionCall = $functionCallPart->getFunctionCall();
    $check($functionCall->getName() === 'workspace_write', 'parsed FunctionCall has correct name');
    $check($functionCall->getId() === 'toolu_123', 'parsed FunctionCall preserves id');
    $args = $functionCall->getArgs();
    $check(is_array($args) && ($args['path'] ?? null) === 'X.md', 'parsed FunctionCall has decoded arguments');
}

if ($failures > 0) {
    fwrite(STDERR, "\n{$failures} structured-tools assertion(s) failed.\n");
    exit(1);
}

echo "\nOK: {$passes} structured-tools assertions passed.\n";
