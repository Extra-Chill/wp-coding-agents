<?php
/**
 * Plugin Name: WP Coding Agents Integration
 * Plugin URI: https://github.com/Extra-Chill/wp-coding-agents
 * Description: Focused WordPress runtime contracts for wp-coding-agents consumers.
 * Requires at least: 6.9
 * Requires PHP: 7.4
 * Version: 0.1.0
 * Author: Extra Chill
 * License: GPL-2.0-or-later
 * License URI: https://spdx.org/licenses/GPL-2.0-or-later.html
 * Text Domain: wp-coding-agents-integration
 *
 * @package WpCodingAgents\Integration
 */

declare(strict_types=1);

if (!defined('ABSPATH')) {
	exit;
}

require_once __DIR__ . '/src/HostCapabilities.php';
