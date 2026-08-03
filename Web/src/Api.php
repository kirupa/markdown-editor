<?php

declare(strict_types=1);

namespace MarkdownEditor;

/**
 * The whole HTTP surface, as a single dispatch table.
 *
 * The web version keeps documents on the server, so the browser needs a way to
 * do what the macOS app does through Foundation: list a folder, read and write
 * UTF-8 Markdown, and copy an image into the document's assets folder. That is
 * the entire API — there is no state on the server between requests.
 */
final class Api
{
    public function __construct(
        private readonly Workspace $workspace,
        private readonly DocumentStore $documents,
        private readonly FileTree $tree,
        private readonly ImageImporter $images,
        private readonly FileManager $files
    ) {
    }

    public static function bootstrap(?string $workspaceRoot = null): self
    {
        $workspace = Workspace::prepare($workspaceRoot);
        return new self(
            $workspace,
            new DocumentStore($workspace),
            new FileTree($workspace),
            new ImageImporter($workspace),
            new FileManager($workspace)
        );
    }

    public function handle(string $method, string $action, array $query, array $files): void
    {
        try {
            // Assets stream bytes rather than JSON, so they bypass dispatch.
            if ($action === 'asset') {
                $this->sendAsset((string) ($query['path'] ?? ''));
                return;
            }
            $payload = $this->dispatch($method, $action, $query, $files);
            $this->send(200, $payload);
        } catch (WorkspaceError $error) {
            $this->send($error->status(), $error->toPayload());
        } catch (\Throwable $error) {
            // Never leak a stack trace to the browser, but never swallow the
            // failure either — the UI shows whatever `error` says (PRD G-6).
            error_log('[markdown-editor] ' . $error->getMessage());
            $this->send(500, [
                'error' => 'The server could not complete that request.',
                'recovery' => 'Check the web server error log for details.',
            ]);
        }
    }

    private function dispatch(string $method, string $action, array $query, array $files): array
    {
        $isPost = strtoupper($method) === 'POST';
        $body = $isPost ? $this->readJsonBody() : [];

        return match ($action) {
            'config' => [
                'workspaceName' => $this->workspace->name(),
                'markdownExtensions' => Workspace::MARKDOWN_EXTENSIONS,
                'imageExtensions' => Workspace::IMAGE_EXTENSIONS,
                'maxUploadBytes' => $this->maxUploadBytes(),
            ],
            'tree' => [
                'path' => (string) ($query['path'] ?? ''),
                'entries' => $this->tree->contents((string) ($query['path'] ?? '')),
                'ancestors' => $this->tree->ancestors((string) ($query['path'] ?? '')),
            ],
            'read' => $this->documents->read($this->requiredString($query, 'path')),
            'exists' => [
                'path' => (string) ($query['path'] ?? ''),
                'exists' => $this->documents->exists((string) ($query['path'] ?? '')),
            ],
            'write' => $this->requirePost($isPost) ?? $this->documents->write(
                $this->requiredString($body, 'path'),
                (string) ($body['text'] ?? ''),
                (bool) ($body['hasByteOrderMark'] ?? false)
            ),
            'create' => $this->requirePost($isPost) ?? $this->documents->create(
                $this->requiredString($body, 'path')
            ),
            'newFolder' => $this->requirePost($isPost) ?? $this->files->createFolder(
                (string) ($body['parent'] ?? ''),
                $this->requiredString($body, 'name')
            ),
            'newDocument' => $this->requirePost($isPost) ?? $this->files->createDocument(
                (string) ($body['parent'] ?? ''),
                $this->requiredString($body, 'name')
            ),
            'rename' => $this->requirePost($isPost) ?? $this->files->rename(
                $this->requiredString($body, 'path'),
                $this->requiredString($body, 'name')
            ),
            'move' => $this->requirePost($isPost) ?? $this->files->move(
                $this->requiredString($body, 'path'),
                (string) ($body['parent'] ?? '')
            ),
            'duplicate' => $this->requirePost($isPost) ?? $this->files->duplicate(
                $this->requiredString($body, 'path')
            ),
            'delete' => $this->requirePost($isPost) ?? $this->files->delete(
                $this->requiredString($body, 'path')
            ),
            'upload' => $this->requirePost($isPost) ?? $this->images->importUpload(
                $this->requiredString($_POST, 'path'),
                $this->requiredUpload($files)
            ),
            default => throw new WorkspaceError(
                'Unknown request: ' . $action,
                'This build of the editor does not support that action.',
                404
            ),
        };
    }

    /**
     * Streams an image so the rendered view can display a document's assets.
     *
     * The path goes through the workspace resolver like every other path, and
     * only known image types are served — this endpoint must never become a
     * way to read arbitrary files out of the workspace.
     */
    private function sendAsset(string $relativePath): void
    {
        $absolute = $this->workspace->resolve($relativePath);
        $extension = strtolower(pathinfo($absolute, PATHINFO_EXTENSION));
        if (!in_array($extension, Workspace::IMAGE_EXTENSIONS, true)) {
            throw new WorkspaceError(
                'That file is not an image.',
                'Only image files can be displayed inside a document.',
                415
            );
        }
        if (!is_file($absolute)) {
            throw new WorkspaceError(
                'The image could not be found.',
                'It may have been renamed or moved out of the document’s assets folder.',
                404
            );
        }

        $types = [
            'png' => 'image/png',
            'jpg' => 'image/jpeg',
            'jpeg' => 'image/jpeg',
            'gif' => 'image/gif',
            'heic' => 'image/heic',
            'heif' => 'image/heif',
            'tiff' => 'image/tiff',
            'tif' => 'image/tiff',
            'bmp' => 'image/bmp',
            'webp' => 'image/webp',
            'svg' => 'image/svg+xml',
        ];

        header('Content-Type: ' . ($types[$extension] ?? 'application/octet-stream'));
        header('Content-Length: ' . (string) filesize($absolute));
        header('Cache-Control: no-cache');
        header('X-Content-Type-Options: nosniff');
        // An SVG is markup the browser executes, so assets are served with
        // nothing enabled and inside a sandbox. Even a file that got past
        // import validation cannot act in the editor's origin.
        header("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; sandbox");
        header('Content-Disposition: inline; filename="' . basename($absolute) . '"');
        readfile($absolute);
    }

    private function requirePost(bool $isPost): ?array
    {
        if (!$isPost) {
            throw new WorkspaceError('That request must be sent as POST.', '', 405);
        }
        return null;
    }

    private function requiredString(array $source, string $key): string
    {
        $value = $source[$key] ?? '';
        if (!is_string($value) || trim($value) === '') {
            throw new WorkspaceError('The request is missing a "' . $key . '" value.');
        }
        return $value;
    }

    /** @return array{name: string, tmp_name: string, error: int, size: int} */
    private function requiredUpload(array $files): array
    {
        $file = $files['image'] ?? null;
        if (!is_array($file) || !isset($file['error'])) {
            throw new WorkspaceError(
                'No image was included in the request.',
                'Choose an image and try again.'
            );
        }
        return $file;
    }

    private function readJsonBody(): array
    {
        $raw = file_get_contents('php://input');
        if ($raw === false || trim($raw) === '') {
            return [];
        }
        $decoded = json_decode($raw, true);
        if (!is_array($decoded)) {
            throw new WorkspaceError('The request body was not valid JSON.');
        }
        return $decoded;
    }

    /** The smaller of the two PHP limits, so the UI can reject early. */
    private function maxUploadBytes(): int
    {
        $toBytes = static function (string $value): int {
            $value = trim($value);
            if ($value === '') {
                return 0;
            }
            $unit = strtolower($value[strlen($value) - 1]);
            $number = (int) $value;
            return match ($unit) {
                'g' => $number * 1024 * 1024 * 1024,
                'm' => $number * 1024 * 1024,
                'k' => $number * 1024,
                default => $number,
            };
        };

        $limits = array_filter([
            $toBytes((string) ini_get('upload_max_filesize')),
            $toBytes((string) ini_get('post_max_size')),
        ]);

        return $limits === [] ? 0 : min($limits);
    }

    private function send(int $status, array $payload): void
    {
        http_response_code($status);
        header('Content-Type: application/json; charset=utf-8');
        header('Cache-Control: no-store');
        header('X-Content-Type-Options: nosniff');
        echo json_encode(
            $payload,
            JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE
        );
    }
}
