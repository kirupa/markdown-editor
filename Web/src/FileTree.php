<?php

declare(strict_types=1);

namespace MarkdownEditor;

/**
 * Directory listing for the file explorer sidebar.
 *
 * Mirrors macOS/Sources/MarkdownEditorCore/FileTreeScanner.swift: hidden files
 * are skipped, expandable folders sort ahead of everything else, and the rest
 * sorts by localized natural order so "Folder 2" precedes "Folder 10"
 * (PRD X-6, X-7, X-8).
 */
final class FileTree
{
    public function __construct(private readonly Workspace $workspace)
    {
    }

    /**
     * One level of `$relativePath`. The sidebar loads lazily, so descending is
     * the client's job.
     *
     * @return list<array<string, mixed>>
     */
    public function contents(string $relativePath): array
    {
        $directory = $this->workspace->resolve($relativePath);
        if (!is_dir($directory)) {
            throw new WorkspaceError(
                'The explorer location is not a folder: ' . basename($directory)
            );
        }

        $names = @scandir($directory);
        if ($names === false) {
            throw new WorkspaceError(
                'The folder could not be read: ' . basename($directory),
                'Check that the web server has permission to read it.'
            );
        }

        $entries = [];
        foreach ($names as $name) {
            if ($name === '.' || $name === '..' || str_starts_with($name, '.')) {
                continue;
            }

            $absolute = $directory . DIRECTORY_SEPARATOR . $name;
            $isLink = is_link($absolute);
            $isDirectory = is_dir($absolute);
            // A bundle such as Foo.app is a directory the user means as a file,
            // so it is listed but never descended into.
            $isPackage = $isDirectory && $this->looksLikePackage($name);

            $entries[] = [
                'name' => $name,
                'path' => $this->workspace->relativePath($directory) === ''
                    ? $name
                    : $this->workspace->relativePath($directory) . '/' . $name,
                'isDirectory' => $isDirectory,
                'isSymbolicLink' => $isLink,
                'isPackage' => $isPackage,
                'isExpandable' => $isDirectory && !$isLink && !$isPackage,
                'isMarkdown' => !$isDirectory && Workspace::isMarkdown($name),
            ];
        }

        usort($entries, static function (array $left, array $right): int {
            if ($left['isExpandable'] !== $right['isExpandable']) {
                return $left['isExpandable'] ? -1 : 1;
            }
            return strnatcasecmp($left['name'], $right['name']);
        });

        return $entries;
    }

    /**
     * Every ancestor of `$relativePath` up to the workspace root, outermost
     * first, for the explorer's path dropdown (PRD X-3). The root is included;
     * nothing above it is, because nothing above it is reachable.
     *
     * @return list<array{name: string, path: string}>
     */
    public function ancestors(string $relativePath): array
    {
        $this->workspace->resolve($relativePath);
        $ancestors = [['name' => $this->workspace->name(), 'path' => '']];

        $components = array_values(array_filter(
            explode('/', str_replace('\\', '/', trim($relativePath, '/'))),
            static fn (string $part): bool => $part !== '' && $part !== '.'
        ));

        $accumulated = '';
        foreach ($components as $component) {
            $accumulated = $accumulated === '' ? $component : $accumulated . '/' . $component;
            $ancestors[] = ['name' => $component, 'path' => $accumulated];
        }

        return $ancestors;
    }

    private function looksLikePackage(string $name): bool
    {
        $extension = strtolower(pathinfo($name, PATHINFO_EXTENSION));
        return in_array(
            $extension,
            ['app', 'bundle', 'framework', 'photoslibrary', 'rtfd', 'xcodeproj'],
            true
        );
    }
}
