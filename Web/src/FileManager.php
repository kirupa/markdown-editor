<?php

declare(strict_types=1);

namespace MarkdownEditor;

/**
 * Creating, renaming, moving, duplicating, and deleting workspace entries.
 *
 * The macOS build hands this job to Finder, which sits right beside the app.
 * The browser has no such neighbour: the documents live on the server, so the
 * editor has to be the file manager too, or the sidebar becomes a window onto
 * a folder nobody can reorganize (PRD WF-*).
 *
 * Every path still goes through {@see Workspace::resolve()}, and every new
 * name goes through {@see assertValidName()} — a name arriving from the client
 * is exactly as untrusted as a path.
 */
final class FileManager
{
    /** The limit on every filesystem the editor is likely to meet. */
    private const MAX_NAME_BYTES = 255;

    public function __construct(private readonly Workspace $workspace)
    {
    }

    /** @return array<string, mixed> */
    public function createFolder(string $parentPath, string $name): array
    {
        $parent = $this->requireFolder($parentPath);
        $name = $this->assertValidName($name);

        $destination = $parent . DIRECTORY_SEPARATOR . $name;
        $this->assertAvailable($destination);

        if (!@mkdir($destination, 0o755)) {
            throw new WorkspaceError(
                'The folder could not be created: ' . $name,
                'Check that the web server can write to ' . $this->describe($parent) . '.'
            );
        }

        return $this->entryFor($destination);
    }

    /**
     * Creates an empty Markdown document, defaulting the extension so a name
     * typed without one still opens.
     *
     * @return array<string, mixed>
     */
    public function createDocument(string $parentPath, string $name): array
    {
        $parent = $this->requireFolder($parentPath);
        $name = $this->assertValidName($this->withMarkdownExtension($name));

        $destination = $parent . DIRECTORY_SEPARATOR . $name;
        $this->assertAvailable($destination);

        if (@file_put_contents($destination, '') === false) {
            throw new WorkspaceError(
                'The document could not be created: ' . $name,
                'Check that the web server can write to ' . $this->describe($parent) . '.'
            );
        }
        @chmod($destination, 0o644);

        return $this->entryFor($destination);
    }

    /**
     * Renames an entry in place.
     *
     * A Markdown document keeps its assets folder: `<stem>.assets` is derived
     * from the filename, so renaming the document without renaming the folder
     * would break every image in it. The folder is renamed alongside and the
     * references inside the document are rewritten to match (WF-8).
     *
     * @return array<string, mixed>
     */
    public function rename(string $path, string $newName): array
    {
        $absolute = $this->workspace->resolveEntry($path);
        $this->assertNotRoot($absolute, 'renamed');

        $newName = $this->assertValidName($this->carryExtension($absolute, $newName));
        $destination = dirname($absolute) . DIRECTORY_SEPARATOR . $newName;
        if ($destination === $absolute) {
            return $this->entryFor($absolute);
        }

        return $this->relocate($absolute, $destination, 'renamed');
    }

    /**
     * Moves an entry into another folder, keeping its name.
     *
     * @return array<string, mixed>
     */
    public function move(string $path, string $destinationFolder): array
    {
        $absolute = $this->workspace->resolveEntry($path);
        $this->assertNotRoot($absolute, 'moved');
        $folder = $this->requireFolder($destinationFolder);

        if ($folder === dirname($absolute)) {
            return $this->entryFor($absolute);
        }
        // Moving a folder inside itself would detach the whole subtree.
        if (is_dir($absolute) && !is_link($absolute)
            && ($folder === $absolute || str_starts_with($folder, $absolute . DIRECTORY_SEPARATOR))
        ) {
            throw new WorkspaceError(
                'A folder cannot be moved inside itself: ' . basename($absolute),
                'Choose a folder that is not ' . basename($absolute) . ' or one of its subfolders.'
            );
        }

        return $this->relocate(
            $absolute,
            $folder . DIRECTORY_SEPARATOR . basename($absolute),
            'moved'
        );
    }

    /**
     * Copies an entry beside itself under the next free `name-2` style name,
     * matching how imported images avoid collisions (I-8).
     *
     * @return array<string, mixed>
     */
    public function duplicate(string $path): array
    {
        $absolute = $this->workspace->resolveEntry($path);
        $this->assertNotRoot($absolute, 'duplicated');

        $destination = $this->nextAvailable(dirname($absolute), basename($absolute));
        $this->assertAssetsAvailable($absolute, $destination);
        $isDirectory = is_dir($absolute) && !is_link($absolute);

        $copied = $isDirectory
            ? $this->copyTree($absolute, $destination)
            : @copy($absolute, $destination);
        if (!$copied) {
            $this->deleteTree($destination);
            throw new WorkspaceError(
                'The copy could not be created: ' . basename($absolute),
                'Check that the web server can write to '
                    . $this->describe(dirname($absolute)) . '.'
            );
        }

        try {
            $this->carryAssets($absolute, $destination, copy: true);
        } catch (WorkspaceError $error) {
            $this->deleteTree($destination);
            throw $error;
        }

        return $this->entryFor($destination);
    }

    /**
     * Deletes a file, or a folder and everything in it.
     *
     * There is no Trash to fall back on, so this is final — the confirmation
     * in front of it is the only safety net (WF-11). A document's assets
     * folder is deliberately left behind: it holds original images the user
     * may not have anywhere else, and it is visible in the sidebar to delete
     * separately.
     *
     * @return array<string, mixed>
     */
    public function delete(string $path): array
    {
        $absolute = $this->workspace->resolveEntry($path);
        $this->assertNotRoot($absolute, 'deleted');

        $entry = $this->entryFor($absolute);
        if (!$this->deleteTree($absolute)) {
            throw new WorkspaceError(
                'The item could not be deleted: ' . basename($absolute),
                'Check that the web server can write to '
                    . $this->describe(dirname($absolute)) . '.'
            );
        }

        return $entry + ['deleted' => true];
    }

    /**
     * The shared tail of rename and move: check, move, keep assets attached,
     * and undo the move if the assets step fails so nothing is left half done.
     *
     * @return array<string, mixed>
     */
    private function relocate(string $absolute, string $destination, string $verb): array
    {
        $this->assertAvailable($destination);
        $this->assertAssetsAvailable($absolute, $destination);

        if (!@rename($absolute, $destination)) {
            throw new WorkspaceError(
                'The item could not be ' . $verb . ': ' . basename($absolute),
                'Check that the web server can write to '
                    . $this->describe(dirname($destination)) . '.'
            );
        }

        try {
            $this->carryAssets($absolute, $destination, copy: false);
        } catch (WorkspaceError $error) {
            @rename($destination, $absolute);
            throw $error;
        }

        return $this->entryFor($destination);
    }

    /** Refuses upfront when the assets folder cannot follow its document. */
    private function assertAssetsAvailable(string $oldDocument, string $newDocument): void
    {
        [$source, $target] = $this->assetsPair($oldDocument, $newDocument);
        if ($source === null || $target === null) {
            return;
        }
        if (file_exists($target) || is_link($target)) {
            throw new WorkspaceError(
                'A folder named ' . basename($target) . ' is already there.',
                'The images belonging to ' . basename($oldDocument)
                    . ' are kept in that folder, so it has to move too.'
            );
        }
    }

    /**
     * Moves or copies `<stem>.assets` so it stays beside its document, then
     * repoints the references inside the document at the new folder name.
     */
    private function carryAssets(string $oldDocument, string $newDocument, bool $copy): void
    {
        [$source, $target] = $this->assetsPair($oldDocument, $newDocument);
        if ($source === null || $target === null) {
            return;
        }

        $moved = $copy ? $this->copyTree($source, $target) : @rename($source, $target);
        if (!$moved) {
            if ($copy) {
                $this->deleteTree($target);
            }
            throw new WorkspaceError(
                'The images folder could not be moved: ' . basename($source),
                'Check that the web server can write to '
                    . $this->describe(dirname($target)) . '.'
            );
        }

        $this->rewriteAssetReferences($newDocument, basename($source), basename($target));
    }

    /**
     * The assets folder to act on and where it belongs, or nulls when there is
     * nothing to do — not a document, no assets folder, or a name that did not
     * actually change.
     *
     * @return array{0: ?string, 1: ?string}
     */
    private function assetsPair(string $oldDocument, string $newDocument): array
    {
        if (!Workspace::isMarkdown($oldDocument) || !Workspace::isMarkdown($newDocument)) {
            return [null, null];
        }

        $sourceName = ImageImporter::assetsDirectoryName($oldDocument);
        $targetName = ImageImporter::assetsDirectoryName($newDocument);
        $source = dirname($oldDocument) . DIRECTORY_SEPARATOR . $sourceName;
        $target = dirname($newDocument) . DIRECTORY_SEPARATOR . $targetName;

        if ($source === $target || !is_dir($source) || is_link($source)) {
            return [null, null];
        }
        return [$source, $target];
    }

    /**
     * Rewrites `Old.assets/` to `New.assets/` inside the document.
     *
     * References are written percent-encoded (I-9), but a hand-typed one may
     * not be, so both spellings are replaced. The bytes are rewritten in place
     * rather than through DocumentStore so a byte-order mark and the original
     * line endings survive untouched.
     */
    private function rewriteAssetReferences(string $document, string $oldName, string $newName): void
    {
        $bytes = @file_get_contents($document);
        if ($bytes === false || $bytes === '') {
            return;
        }

        $search = [ImageImporter::encodeComponent($oldName) . '/'];
        $replace = [ImageImporter::encodeComponent($newName) . '/'];
        if ($search[0] !== $oldName . '/') {
            $search[] = $oldName . '/';
            $replace[] = $newName . '/';
        }

        $updated = str_replace($search, $replace, $bytes);
        if ($updated !== $bytes) {
            @file_put_contents($document, $updated);
        }
    }

    /**
     * A name is only ever a single path component. Anything that could make it
     * more than that, hide it from the sidebar, or corrupt the display is
     * refused rather than sanitized, so the user sees the name they typed or a
     * reason they cannot have it.
     */
    private function assertValidName(string $name): string
    {
        $name = trim($name);

        if ($name === '') {
            throw new WorkspaceError('Enter a name.');
        }
        if ($name === '.' || $name === '..') {
            throw new WorkspaceError(
                'That name is reserved: ' . $name,
                'Choose a different name.'
            );
        }
        if (str_contains($name, '/') || str_contains($name, '\\')) {
            throw new WorkspaceError(
                'A name cannot contain a slash.',
                'Slashes separate folders, so they cannot be part of a single name.'
            );
        }
        if (preg_match('/[\x00-\x1F\x7F]/', $name) === 1) {
            throw new WorkspaceError('That name contains a character that is not allowed.');
        }
        if (str_starts_with($name, '.')) {
            throw new WorkspaceError(
                'A name cannot start with a period.',
                'The sidebar hides those files, so the new item would disappear.'
            );
        }
        if (strlen($name) > self::MAX_NAME_BYTES) {
            throw new WorkspaceError(
                'That name is too long.',
                'Names are limited to ' . self::MAX_NAME_BYTES . ' bytes.'
            );
        }
        if (!mb_check_encoding($name, 'UTF-8')) {
            throw new WorkspaceError('That name is not valid UTF-8.');
        }

        return $name;
    }

    /**
     * Keeps a Markdown document openable through a rename: a new name with no
     * extension inherits the old one, and a new name with a different
     * extension is refused rather than quietly orphaning the document (WF-7).
     */
    private function carryExtension(string $absolute, string $newName): string
    {
        $newName = trim($newName);
        if (!is_file($absolute) || !Workspace::isMarkdown($absolute) || $newName === '') {
            return $newName;
        }
        if (Workspace::isMarkdown($newName)) {
            return $newName;
        }

        $extension = pathinfo($newName, PATHINFO_EXTENSION);
        if ($extension === '') {
            return $newName . '.' . pathinfo($absolute, PATHINFO_EXTENSION);
        }

        throw new WorkspaceError(
            'Markdown documents must end in .md or .markdown.',
            'The editor cannot open a file named ' . $newName . '.'
        );
    }

    private function withMarkdownExtension(string $name): string
    {
        $name = trim($name);
        return $name === '' || Workspace::isMarkdown($name) ? $name : $name . '.md';
    }

    /** `name-2.md`, then `name-3.md`, matching the image importer (I-8). */
    private function nextAvailable(string $directory, string $fileName): string
    {
        $stem = pathinfo($fileName, PATHINFO_FILENAME);
        $extension = pathinfo($fileName, PATHINFO_EXTENSION);

        for ($suffix = 2; $suffix < 10_000; $suffix += 1) {
            $candidate = $extension === ''
                ? $stem . '-' . $suffix
                : $stem . '-' . $suffix . '.' . $extension;
            $path = $directory . DIRECTORY_SEPARATOR . $candidate;
            if (!file_exists($path) && !is_link($path)) {
                return $path;
            }
        }

        throw new WorkspaceError(
            'There are too many copies of ' . $fileName . ' already.',
            'Rename or remove some of them and try again.'
        );
    }

    /**
     * Copies a directory tree. Symbolic links are recreated as links rather
     * than followed, so a link out of the workspace cannot be used to pull
     * files in or to write through.
     */
    private function copyTree(string $source, string $destination): bool
    {
        if (is_link($source)) {
            $target = @readlink($source);
            return $target !== false && @symlink($target, $destination);
        }
        if (!is_dir($source)) {
            return @copy($source, $destination);
        }
        if (!@mkdir($destination, 0o755) && !is_dir($destination)) {
            return false;
        }

        $names = @scandir($source);
        if ($names === false) {
            return false;
        }
        foreach ($names as $name) {
            if ($name === '.' || $name === '..') {
                continue;
            }
            if (!$this->copyTree(
                $source . DIRECTORY_SEPARATOR . $name,
                $destination . DIRECTORY_SEPARATOR . $name
            )) {
                return false;
            }
        }
        return true;
    }

    /**
     * Removes a file, link, or directory tree. A symbolic link is unlinked and
     * never descended into, so deleting a folder can only ever delete what is
     * really inside it.
     */
    private function deleteTree(string $absolute): bool
    {
        if ($absolute === '' || (!file_exists($absolute) && !is_link($absolute))) {
            return true;
        }
        if (is_link($absolute) || !is_dir($absolute)) {
            return @unlink($absolute);
        }

        $names = @scandir($absolute);
        if ($names === false) {
            return false;
        }
        foreach ($names as $name) {
            if ($name === '.' || $name === '..') {
                continue;
            }
            if (!$this->deleteTree($absolute . DIRECTORY_SEPARATOR . $name)) {
                return false;
            }
        }
        return @rmdir($absolute);
    }

    private function requireFolder(string $relativePath): string
    {
        $absolute = $this->workspace->resolve($relativePath);
        if (!is_dir($absolute)) {
            throw new WorkspaceError(
                'That is not a folder: ' . basename($absolute),
                'New items can only be created inside a folder.'
            );
        }
        return $absolute;
    }

    private function assertAvailable(string $absolute): void
    {
        if (file_exists($absolute) || is_link($absolute)) {
            throw new WorkspaceError(
                'An item named ' . basename($absolute) . ' is already there.',
                'Choose a different name.'
            );
        }
    }

    private function assertNotRoot(string $absolute, string $verb): void
    {
        if ($absolute === $this->workspace->root()) {
            throw new WorkspaceError(
                'The workspace folder itself cannot be ' . $verb . '.',
                'Only items inside ' . $this->workspace->name() . ' can be changed here.'
            );
        }
    }

    /** The workspace name for the root, and a plain folder name below it. */
    private function describe(string $absolute): string
    {
        return $absolute === $this->workspace->root()
            ? $this->workspace->name()
            : basename($absolute);
    }

    /** @return array<string, mixed> */
    private function entryFor(string $absolute): array
    {
        $relative = $this->workspace->relativePath($absolute);
        $isDirectory = is_dir($absolute);
        $isLink = is_link($absolute);

        return [
            'name' => basename($absolute),
            'path' => $relative,
            'parent' => str_contains($relative, '/') ? dirname($relative) : '',
            'isDirectory' => $isDirectory,
            'isSymbolicLink' => $isLink,
            'isExpandable' => $isDirectory && !$isLink,
            'isMarkdown' => !$isDirectory && Workspace::isMarkdown($absolute),
        ];
    }
}
