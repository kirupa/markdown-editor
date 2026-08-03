<?php

declare(strict_types=1);

/**
 * The editor's only server endpoint.
 *
 * Everything lives behind `?action=`, so the app works unchanged on any PHP
 * host without rewrite rules, virtual-host configuration, or a router.
 */

// A shared host rarely lets you repoint the document root, so the public files
// end up in a URL subdirectory while the rest of the app stays above it, out
// of reach of the web. MARKDOWN_EDITOR_HOME names that private folder; unset,
// the layout is the one in this repository.
$home = getenv('MARKDOWN_EDITOR_HOME') ?: ($_SERVER['MARKDOWN_EDITOR_HOME'] ?? '');
require (is_string($home) && $home !== '' ? rtrim($home, '/\\') : __DIR__ . '/..')
    . '/bootstrap.php';

use MarkdownEditor\Api;
use MarkdownEditor\WorkspaceError;

try {
    $api = Api::bootstrap();
} catch (WorkspaceError $error) {
    http_response_code(500);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($error->toPayload(), JSON_UNESCAPED_SLASHES);
    exit;
}

$api->handle(
    $_SERVER['REQUEST_METHOD'] ?? 'GET',
    (string) ($_GET['action'] ?? ''),
    $_GET,
    $_FILES
);
