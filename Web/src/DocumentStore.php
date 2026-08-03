<?php

declare(strict_types=1);

namespace MarkdownEditor;

/**
 * Reading and writing Markdown documents.
 *
 * Mirrors MarkdownTextCodec.swift and the document lifecycle requirements:
 * UTF-8 in and out (D-8), a byte-order mark that survives a round trip without
 * being introduced where there was none (D-9), byte-exact line endings (D-10),
 * and a clear refusal on anything that is not valid UTF-8 (D-11).
 */
final class DocumentStore
{
    private const BYTE_ORDER_MARK = "\xEF\xBB\xBF";

    public function __construct(private readonly Workspace $workspace)
    {
    }

    /** @return array<string, mixed> */
    public function read(string $relativePath): array
    {
        $absolute = $this->workspace->resolve($relativePath);
        if (is_dir($absolute)) {
            throw new WorkspaceError(
                'That is a folder, not a Markdown document: ' . basename($absolute)
            );
        }
        if (!Workspace::isMarkdown($absolute)) {
            throw new WorkspaceError(
                'Only .md and .markdown files can be opened.',
                'The file ' . basename($absolute) . ' has a different extension.'
            );
        }

        $bytes = @file_get_contents($absolute);
        if ($bytes === false) {
            throw new WorkspaceError(
                'The file could not be read: ' . basename($absolute),
                'Check that the web server has permission to read it.'
            );
        }

        // Validate before stripping, so a BOM cannot mask invalid bytes.
        if (!mb_check_encoding($bytes, 'UTF-8')) {
            throw new WorkspaceError(
                'The file is not valid UTF-8 Markdown.',
                'Convert the file to UTF-8 and try opening it again.'
            );
        }

        $hasByteOrderMark = str_starts_with($bytes, self::BYTE_ORDER_MARK);
        $text = $hasByteOrderMark
            ? substr($bytes, strlen(self::BYTE_ORDER_MARK))
            : $bytes;

        return [
            'path' => $this->workspace->relativePath($absolute),
            'name' => basename($absolute),
            'text' => $text,
            'hasByteOrderMark' => $hasByteOrderMark,
            'modified' => filemtime($absolute) ?: 0,
            'size' => strlen($bytes),
        ];
    }

    /**
     * Writes `$text` to `$relativePath`, creating the file when needed.
     *
     * The write goes to a sibling temporary file that is then renamed over the
     * target, so an interrupted save cannot leave a half-written document
     * behind. Autosave runs this every 1.5 seconds (D-12), which is exactly
     * when a torn write would be most likely and most costly.
     *
     * @return array<string, mixed>
     */
    public function write(
        string $relativePath,
        string $text,
        bool $includeByteOrderMark = false
    ): array {
        $absolute = $this->workspace->resolve($relativePath, mustExist: false);
        if (!Workspace::isMarkdown($absolute)) {
            throw new WorkspaceError(
                'Markdown documents must end in .md or .markdown.',
                'Rename ' . basename($absolute) . ' and try again.'
            );
        }
        if (is_dir($absolute)) {
            throw new WorkspaceError(
                'A folder already exists at that location: ' . basename($absolute)
            );
        }
        if (!mb_check_encoding($text, 'UTF-8')) {
            throw new WorkspaceError('The document text is not valid UTF-8.');
        }

        $bytes = ($includeByteOrderMark ? self::BYTE_ORDER_MARK : '') . $text;
        $directory = dirname($absolute);
        $temporary = @tempnam($directory, '.md-save-');
        if ($temporary === false) {
            throw new WorkspaceError(
                'The document could not be saved: ' . basename($absolute),
                'Check that the web server can write to ' . basename($directory) . '.'
            );
        }

        if (@file_put_contents($temporary, $bytes) !== strlen($bytes)
            || !@rename($temporary, $absolute)
        ) {
            @unlink($temporary);
            throw new WorkspaceError(
                'The document could not be saved: ' . basename($absolute),
                'Check that the web server can write to ' . basename($directory) . '.'
            );
        }
        @chmod($absolute, 0o644);
        clearstatcache(true, $absolute);

        return [
            'path' => $this->workspace->relativePath($absolute),
            'name' => basename($absolute),
            'modified' => filemtime($absolute) ?: 0,
            'size' => strlen($bytes),
        ];
    }

    /**
     * Creates an empty document, refusing to clobber an existing one.
     *
     * @return array<string, mixed>
     */
    public function create(string $relativePath): array
    {
        $absolute = $this->workspace->resolve($relativePath, mustExist: false);
        if (file_exists($absolute)) {
            throw new WorkspaceError(
                'A file already exists at that location: ' . basename($absolute),
                'Choose a different name.'
            );
        }
        return $this->write($relativePath, '');
    }

    /** Whether a recorded recent document is still openable (PRD W-17). */
    public function exists(string $relativePath): bool
    {
        try {
            $absolute = $this->workspace->resolve($relativePath);
        } catch (WorkspaceError) {
            return false;
        }
        return is_file($absolute) && Workspace::isMarkdown($absolute);
    }
}
