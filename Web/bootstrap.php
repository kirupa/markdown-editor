<?php

declare(strict_types=1);

/**
 * Class loading, without Composer.
 *
 * The whole point of this build is that a PHP host with nothing installed on
 * it can serve the app, so autoloading is nine lines rather than a vendor
 * directory.
 */

spl_autoload_register(static function (string $class): void {
    $prefix = 'MarkdownEditor\\';
    if (!str_starts_with($class, $prefix)) {
        return;
    }

    $relative = substr($class, strlen($prefix));
    $path = __DIR__ . '/src/' . str_replace('\\', '/', $relative) . '.php';
    if (is_file($path)) {
        require $path;
    }
});
