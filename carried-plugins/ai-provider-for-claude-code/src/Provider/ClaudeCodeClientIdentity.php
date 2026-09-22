<?php

declare(strict_types=1);

namespace ExtraChill\ClaudeCodeAiProvider\Provider;

/** Resolves public client metadata independently of the installed CLI and OAuth tokens. */
class ClaudeCodeClientIdentity
{
    private const FALLBACK_VERSION = '2.1.280';
    private const CACHE_OPTION = 'ai_provider_claude_code_client_version';
    private const REGISTRY_URL = 'https://registry.npmjs.org/@anthropic-ai/claude-code/latest';
    private const TTL = 21600;
    private const RETRY_DELAY = 300;

    /** @var array|null Process-local fallback when persistent storage is unavailable. */
    private static $cache;

    public static function userAgent(): string
    {
        $override = getenv('AI_PROVIDER_CLAUDE_CODE_USER_AGENT') ?: '';
        if (defined('AI_PROVIDER_CLAUDE_CODE_USER_AGENT')) {
            $override = (string) constant('AI_PROVIDER_CLAUDE_CODE_USER_AGENT');
        }
        if ($override !== '') {
            return $override;
        }

        $now = time();
        if (self::$cache === null) {
            $stored = get_option(self::CACHE_OPTION, array());
            $valid = is_array($stored) && self::validVersion($stored['version'] ?? null);
            self::$cache = array(
                'version' => $valid ? $stored['version'] : self::FALLBACK_VERSION,
                'next_check' => $valid && is_int($stored['next_check'] ?? null) && $stored['next_check'] <= $now + self::TTL ? $stored['next_check'] : 0,
            );
        }
        if (self::$cache['next_check'] <= $now) {
            $delay = self::RETRY_DELAY;
            $response = wp_remote_get(self::REGISTRY_URL, array(
                'timeout' => 3,
                'redirection' => 0,
                'limit_response_size' => 65536,
                'headers' => array('Accept' => 'application/json'),
            ));
            if (!is_wp_error($response) && wp_remote_retrieve_response_code($response) === 200) {
                $metadata = json_decode(wp_remote_retrieve_body($response), true);
                if (is_array($metadata) && self::validVersion($metadata['version'] ?? null)) {
                    self::$cache['version'] = $metadata['version'];
                    $delay = self::TTL;
                }
            }
            self::$cache['next_check'] = time() + $delay;
            // Non-expiring storage retains the last good value through registry outages.
            update_option(self::CACHE_OPTION, self::$cache, false);
        }

        return 'claude-cli/' . self::$cache['version'];
    }

    private static function validVersion($value): bool
    {
        return is_string($value) && strlen($value) < 40 && preg_match('/\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/', $value) === 1;
    }
}
