<?php

declare(strict_types=1);

spl_autoload_register(static function (string $class): void {
    $prefix = 'ExtraChill\\ClaudeCodeAiProvider\\';
    $baseDir = __DIR__ . '/';

    $len = strlen($prefix);
    if (strncmp($class, $prefix, $len) !== 0) {
        return;
    }

    $relativeClass = substr($class, $len);
    $file = $baseDir . str_replace('\\', '/', $relativeClass) . '.php';

    if (file_exists($file)) {
        require $file;
    }
});
