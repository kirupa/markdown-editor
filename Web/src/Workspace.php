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

    /** The folder the editor opens when nothing else is configured (WW-1). */
    public const DEFAULT_FOLDER_NAME = 'kirupaMarkdown';

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

    /**
     * Where the editor keeps documents when nothing is configured (WW-1).
     *
     * A personal notes folder in the home directory rather than one inside the
     * checkout, so pulling a new version of the editor can never touch the
     * user's documents, and so the folder can be moved into a sync service.
     * `MARKDOWN_EDITOR_WORKSPACE` still wins when it is set. The last resort
     * sits beside the code, for hosts where the account has no usable home.
     */
    public static function defaultRoot(): string
    {
        $configured = self::env('MARKDOWN_EDITOR_WORKSPACE');
        if ($configured !== null) {
            return rtrim($configured, DIRECTORY_SEPARATOR) ?: $configured;
        }

        $home = self::env('HOME') ?? '';
        if ($home !== '' && $home !== '/' && is_dir($home) && is_writable($home)) {
            return rtrim($home, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . self::DEFAULT_FOLDER_NAME;
        }

        return dirname(__DIR__) . DIRECTORY_SEPARATOR . self::DEFAULT_FOLDER_NAME;
    }

    /**
     * One setting, from wherever this SAPI happens to keep it.
     *
     * `putenv` reaches only `getenv`, and a value set by the web server with
     * `SetEnv` reaches only `$_SERVER` under some CGI and LiteSpeed builds, so
     * reading one of the two is enough to work locally and fail on a host.
     */
    private static function env(string $name): ?string
    {
        $value = getenv($name);
        if (!is_string($value) || trim($value) === '') {
            $value = $_SERVER[$name] ?? null;
        }

        return is_string($value) && trim($value) !== '' ? trim($value) : null;
    }

    /**
     * Opens `$root`, creating it the first time.
     *
     * The constructor deliberately refuses a folder that is not there, because
     * every other caller is handling a path that is supposed to exist already.
     * Startup is the one place where absence is expected rather than an error,
     * so it is the one place allowed to create the folder — and, when it does,
     * to copy in the starter documents so a new install is not an empty pane.
     */
    public static function prepare(?string $root = null): self
    {
        $root = $root ?? self::defaultRoot();
        $created = false;

        if (!is_dir($root)) {
            if (!@mkdir($root, 0o755, true) && !is_dir($root)) {
                throw new WorkspaceError(
                    'The workspace folder could not be created: ' . $root,
                    'Create it by hand, or point MARKDOWN_EDITOR_WORKSPACE at a folder that exists.'
                );
            }
            $created = true;
        }

        $workspace = new self($root);
        if ($created) {
            $workspace->seed(dirname(__DIR__) . DIRECTORY_SEPARATOR . 'seed');
        }
        return $workspace;
    }

    /**
     * Copies the starter documents in. Best effort: a workspace that opens with
     * nothing in it is a far better outcome than one that refuses to open.
     */
    private function seed(string $template): void
    {
        if (!is_dir($template)) {
            return;
        }

        $entries = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($template, \FilesystemIterator::SKIP_DOTS),
            \RecursiveIteratorIterator::SELF_FIRST
        );

        foreach ($entries as $entry) {
            /** @var \SplFileInfo $entry */
            $relative = substr($entry->getPathname(), strlen($template) + 1);
            $destination = $this->root . DIRECTORY_SEPARATOR . $relative;
            if ($entry->isDir()) {
                @mkdir($destination, 0o755, true);
            } elseif (!file_exists($destination)) {
                @copy($entry->getPathname(), $destination);
            }
        }
    }

    /**
     * The name to show for the workspace.
     *
     * iCloud Drive lives at a path whose last component is an internal
     * identifier, so it gets the name Finder shows rather than
     * `com~apple~CloudDocs`.
     */
    public function name(): string
    {
        $name = basename($this->root);
        return $name === 'com~apple~CloudDocs' ? 'iCloud Drive' : $name;
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

    /**
     * Resolves an item the caller means to act *on* rather than read through.
     *
     * {@see resolve()} follows symbolic links, which is right for opening a
     * file — a link out of the workspace has to be refused. It is wrong for
     * renaming or deleting: `Linked` pointing at `Notes` would resolve to
     * `Notes`, and deleting it would destroy the real folder instead of the
     * link. Every ancestor is still resolved and checked, so this cannot be
     * used to reach outside; only the last component is left alone.
     */
    public function resolveEntry(string $relativePath): string
    {
        $relative = $this->normalizeRelativePath($relativePath);
        if ($relative === '') {
            return $this->root;
        }

        $absolute = $this->root . DIRECTORY_SEPARATOR . $relative;
        $parent = realpath(dirname($absolute));
        if ($parent === false) {
            throw new WorkspaceError(
                'The containing folder does not exist: ' . dirname($relative),
                'It may have been moved, renamed, or deleted.'
            );
        }
        $this->assertInsideRoot($parent, $relativePath);

        $entry = $parent . DIRECTORY_SEPARATOR . basename($absolute);
        if (!file_exists($entry) && !is_link($entry)) {
            throw new WorkspaceError(
                'The file does not exist: ' . $relative,
                'It may have been moved, renamed, or deleted.'
            );
        }
        return $entry;
    }

    /** Absolute path back to the workspace-relative form used by the client. */    public function relativePath(string $absolutePath): string
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
