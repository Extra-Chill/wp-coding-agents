<?php

/**
 * Plugin Name: AI Provider for Claude Code
 * Plugin URI: https://github.com/Extra-Chill/wp-coding-agents
 * Description: WP AI Client provider backed by the locally authenticated Claude Code CLI.
 * Requires at least: 6.9
 * Requires PHP: 7.4
 * Version: 0.1.0
 * Author: Extra Chill
 * License: GPL-2.0-or-later
 * License URI: https://spdx.org/licenses/GPL-2.0-or-later.html
 * Text Domain: ai-provider-for-claude-code
 *
 * @package ExtraChill\ClaudeCodeAiProvider
 */

declare(strict_types=1);

namespace ExtraChill\ClaudeCodeAiProvider;

use ExtraChill\ClaudeCodeAiProvider\Provider\ClaudeCodeProvider;
use WordPress\AiClient\AiClient;

if (!defined('ABSPATH')) {
    return;
}

require_once __DIR__ . '/src/autoload.php';

/**
 * Registers the Claude Code provider with the WP AI Client registry.
 *
 * @return void
 */
function register_provider(): void
{
    if (!class_exists(AiClient::class)) {
        return;
    }

    $registry = AiClient::defaultRegistry();

    if (!$registry->hasProvider(ClaudeCodeProvider::class)) {
        $registry->registerProvider(ClaudeCodeProvider::class);
    }
}

add_action('init', __NAMESPACE__ . '\\register_provider', 5);
