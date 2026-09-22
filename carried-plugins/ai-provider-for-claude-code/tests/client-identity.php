<?php
/** Exercise resolver behavior using the WordPress HTTP/storage boundaries. */
namespace ExtraChill\ClaudeCodeAiProvider\Provider {
    function time() { return $GLOBALS['now']; }
}
namespace {
    require_once __DIR__ . '/../src/autoload.php';
    use ExtraChill\ClaudeCodeAiProvider\Provider\ClaudeCodeClientIdentity;

    $now = 1800000000;
    $stored = array();
    $calls = 0;
    $version = '2.1.999';
    $status = 200;
    $offline = false;
    $writable = true;
    function check($condition, $message) {
        if (!$condition) { throw new \RuntimeException($message); }
    }
    function get_option($key, $default) { return $GLOBALS['stored']; }
    function update_option($key, $value, $autoload) {
        check($autoload === false, 'metadata is not autoloaded');
        if (!$GLOBALS['writable']) { return false; }
        $GLOBALS['stored'] = $value;
        return true;
    }
    function wp_remote_get($url, $args) {
        $GLOBALS['calls']++;
        check($url === 'https://registry.npmjs.org/@anthropic-ai/claude-code/latest', 'fixed public registry');
        check($args['timeout'] === 3 && $args['redirection'] === 0 && $args['limit_response_size'] === 65536, 'bounded lookup');
        check($args['headers'] === array('Accept' => 'application/json'), 'no OAuth credentials sent');
        return $GLOBALS['offline'] ? new \stdClass() : array('status' => $GLOBALS['status'], 'body' => json_encode(array('version' => $GLOBALS['version'])));
    }
    function is_wp_error($response) { return is_object($response); }
    function wp_remote_retrieve_response_code($response) { return $response['status']; }
    function wp_remote_retrieve_body($response) { return $response['body']; }
    function restartResolver() {
        $property = new \ReflectionProperty(ClaudeCodeClientIdentity::class, 'cache');
        if (PHP_VERSION_ID < 80100) { $property->setAccessible(true); }
        $property->setValue(null, null);
    }
    putenv('AI_PROVIDER_CLAUDE_CODE_USER_AGENT=custom-client');
    check(ClaudeCodeClientIdentity::userAgent() === 'custom-client' && $calls === 0, 'override skips registry');
    putenv('AI_PROVIDER_CLAUDE_CODE_USER_AGENT');
    check(ClaudeCodeClientIdentity::userAgent() === 'claude-cli/2.1.999', 'registry version');
    check($calls === 1, 'one lookup');
    restartResolver();
    check(ClaudeCodeClientIdentity::userAgent() === 'claude-cli/2.1.999' && $calls === 1, 'persistent cache');
    $now += 21601;
    $version = '2.2.0';
    check(ClaudeCodeClientIdentity::userAgent() === 'claude-cli/2.2.0', 'long-running refresh');
    $now += 21601;
    foreach (array('2.3.0-beta.1', "2.3.0\r\nInjected: yes", '02.3.0', null, "2.3.0\n") as $version) {
        check(ClaudeCodeClientIdentity::userAgent() === 'claude-cli/2.2.0', 'invalid metadata retains last good version');
        $count = $calls;
        ClaudeCodeClientIdentity::userAgent();
        check($calls === $count, 'failure backoff');
        $now += 301;
    }
    $offline = true;
    restartResolver();
    check(ClaudeCodeClientIdentity::userAgent() === 'claude-cli/2.2.0', 'timeout/offline WP_Error retains last good version');
    $stored = array();
    restartResolver();
    check(ClaudeCodeClientIdentity::userAgent() === 'claude-cli/2.1.280', 'offline bootstrap');
    $now += 301;
    $offline = false;
    $version = '2.4.0';
    check(ClaudeCodeClientIdentity::userAgent() === 'claude-cli/2.4.0', 'recovery after outage');
    $now += 21601;
    $status = 503;
    check(ClaudeCodeClientIdentity::userAgent() === 'claude-cli/2.4.0', 'HTTP error fallback');
    $status = 200;
    $stored = array('version' => 'invalid', 'next_check' => $now + 999999999);
    restartResolver();
    check(ClaudeCodeClientIdentity::userAgent() === 'claude-cli/2.4.0', 'malformed cache recovers');
    $writable = false;
    $now += 21601;
    ClaudeCodeClientIdentity::userAgent();
    $count = $calls;
    ClaudeCodeClientIdentity::userAgent();
    check($calls === $count, 'process cache survives storage failure');
    define('AI_PROVIDER_CLAUDE_CODE_USER_AGENT', 'constant-client');
    putenv('AI_PROVIDER_CLAUDE_CODE_USER_AGENT=env-client');
    check(ClaudeCodeClientIdentity::userAgent() === 'constant-client' && $calls === $count, 'constant override wins');
    echo "PASS: dynamic PHP client identity\n";
}
