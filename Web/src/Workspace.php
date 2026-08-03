<?php

declare(strict_types=1);

namespace MarkdownEditor;

/**
 * A rooted view of the directory the editor is allowed to touch.
 *
 * Every path that arrives from the browser is relative and untrusted, so all
 * of them are funneled through {@see resolve()}. Nothing else in the codebase
 * is permitted to concatenate a client string onto a filesystem path.
 */
final class Workspace
{
    /** Extensions the editor treats as Markdown documents (PRD D-2). */
    public const MARKDOWN_EXTENSIONS = ['md', 'markdown'];

    /** Importable image extensions (PRD I-5). */
    public const IMAGE_EXTENSIONS = [
        'bmp', 'gif', 'heic', 'heif', 'jpeg', 'jpg',
        'png', 'svg', 'tif', 'tiff', 'webp',
    ];

    private string $root;

    public function __construct(string $root)
    {
        $resolved = realpath($root);
        if ($resolved === false || !is_dir($resolved)) {
            throw new WorkspaceError(
                'The workspace folder does not exist.',
                'Create ' . $root . ' or point MARKDOWN_EDITOR_WORKSPACE at an existing folder.'
            );
        }
        $this->root = $resolved;
    }

    public function root(): string
    {
        return $this->root;
    }

    public function name(): string
    {
        return basename($this->root);
    }

    /**
     * Turns an untrusted relative path into an absolute path inside the root.
     *
     * `realpath()` alone is not enough: it returns false for a file that does
     * not exist yet, which is exactly the case when saving a new document. So
     * the parent directory is resolved instead — it must exist and must be
     * inside the root — and the final component is appended afterwards. Because
     * the check runs on the resolved parent, a symlink pointing outside the
     * workspace cannot be used to escape it.
     */
    public function resolve(string $relativePath, bool $mustExist = true): string
    {
        $relative = $this->normalizeRelativePath($relativePath);
        if ($relative === '') {
            return $this->root;
        }

        $absolute = $this->root . DIRECTORY_SEPARATOR . $relative;
        $existing = realpath($absolute);
        if ($existing !== false) {
            $this->assertInsideRoot($existing, $relativePath);
            return $existing;
        }

        if ($mustExist) {
            throw new WorkspaceError(
                'The file does not exist: ' . $relative,
                'It may have been moved, renamed, or deleted.'
            );
        }

        $parent = realpath(dirname($absolute));
        if ($parent === false) {
            throw new WorkspaceError(
                'The containing folder does not exist: ' . dirname($relative),
                'Create the folder before saving into it.'
            );
        }
        $this->assertInsideRoot($parent, $relativePath);

        return $parent . DIRECTORY_SEPARATOR . basename($absolute);
    }

    /** Absolute path back to the workspace-relative form used by the client. */
    public function relativePath(string $absolutePath): string
    {
        if ($absolutePath === $this->root) {
            return '';
        }
        $prefix = $this->root . DIRECTORY_SEPARATOR;
        if (!str_starts_with($absolutePath, $prefix)) {
            throw new WorkspaceError('The path is outside the workspace folder.');
        }
        return substr($absolutePath, strlen($prefix));
    }

    /**
     * Rejects absolute paths, parent traversal, and NUL bytes before any of it
     * reaches the filesystem, and collapses the rest to a clean relative path.
     */
    private function normalizeRelativePath(string $path): string
    {
        if (str_contains($path, "\0")) {
            throw new WorkspaceError('The path contains an invalid character.');
        }

        $path = str_replace('\\', '/', trim($path));
        if ($path === '' || $path === '.' || $path === '/') {
            return '';
        }
        if (str_starts_with($path, '/') || preg_match('#^[A-Za-z]:#', $path) === 1) {
            throw new WorkspaceError(
                'Only paths inside the workspace folder can be opened.',
                'Absolute paths are not accepted.'
            );
        }

        $components = [];
        foreach (explode('/', $path) as $component) {
            if ($component === '' || $component === '.') {
                continue;
            }
            if ($component === '..') {
                throw new WorkspaceError(
                    'Only paths inside the workspace folder can be opened.',
                    'Paths may not step outside the workspace with "..".'
                );
            }
            $components[] = $component;
        }

        return implode(DIRECTORY_SEPARATOR, $components);
    }

    private function assertInsideRoot(string $absolutePath, string $reported): void
    {
        if ($absolutePath !== $this->root
            && !str_starts_with($absolutePath, $this->root . DIRECTORY_SEPARATOR)
        ) {
            throw new WorkspaceError(
                'Only paths inside the workspace folder can be opened.',
                'The path "' . $reported . '" resolves outside the workspace.'
            );
        }
    }

    public static function isMarkdown(string $path): bool
    {
        $extension = strtolower(pathinfo($path, PATHINFO_EXTENSION));
        return in_array($extension, self::MARKDOWN_EXTENSIONS, true);
    }

    public static function isSupportedImage(string $path): bool
    {
        $extension = strtolower(pathinfo($path, PATHINFO_EXTENSION));
        return in_array($extension, self::IMAGE_EXTENSIONS, true);
    }
}
