<?php

declare(strict_types=1);

/**
 * The editor's only server endpoint.
 *
 * Everything lives behind `?action=`, so the app works unchanged on any PHP
 * host without rewrite rules, virtual-host configuration, or a router.
 */

require __DIR__ . '/../bootstrap.php';

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
