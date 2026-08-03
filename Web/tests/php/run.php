<?php

declare(strict_types=1);

/**
 * Server-side tests.
 *
 * Run with `php Web/tests/php/run.php`. They cover the parts of the backend
 * that can be got wrong quietly: path containment, UTF-8 handling, and image
 * import naming. Everything else is thin enough to read.
 */

require __DIR__ . '/harness.php';
require dirname(__DIR__, 2) . '/bootstrap.php';

use MarkdownEditor\DocumentStore;
use MarkdownEditor\FileManager;
use MarkdownEditor\FileTree;
use MarkdownEditor\ImageImporter;
use MarkdownEditor\Workspace;

/** Removes a temporary tree, links first so nothing outside it is followed. */function removeTree(string $root): void
{
    if (!is_dir($root)) {
        @unlink($root);
        return;
    }
    foreach (scandir($root) ?: [] as $name) {
        if ($name === '.' || $name === '..') {
            continue;
        }
        $path = $root . DIRECTORY_SEPARATOR . $name;
        is_link($path) || !is_dir($path) ? @unlink($path) : removeTree($path);
    }
    @rmdir($root);
}

/** A disposable workspace, removed when the process ends. */
function makeWorkspace(): array
{
    $root = sys_get_temp_dir() . '/markdown-editor-tests-' . bin2hex(random_bytes(6));
    mkdir($root . '/Notes', 0o777, true);
    file_put_contents($root . '/Notes/Ideas.md', "# Ideas\n\n- one\n");
    file_put_contents($root . '/Readme.markdown', "# Readme\n");
    file_put_contents($root . '/photo.png', base64_decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
    ));
    file_put_contents($root . '/.hidden.md', "# Hidden\n");

    register_shutdown_function(static fn () => removeTree($root));

    $workspace = new Workspace($root);
    return [
        $workspace,
        new DocumentStore($workspace),
        new FileTree($workspace),
        new ImageImporter($workspace),
        // The resolved root, since macOS reports /var as /private/var.
        $workspace->root(),
        new FileManager($workspace),
    ];
}

/** Minimal but genuine bytes for each format the importer accepts. */
function makeImageBytes(string $extension): string
{
    return match ($extension) {
        'png' => base64_decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
        ),
        'jpg', 'jpeg' => "\xFF\xD8\xFF\xE0" . str_repeat("\x00", 16),
        'gif' => 'GIF89a' . str_repeat("\x00", 16),
        'bmp' => 'BM' . str_repeat("\x00", 16),
        'tif', 'tiff' => "II\x2A\x00" . str_repeat("\x00", 16),
        'webp' => 'RIFF' . "\x00\x00\x00\x00" . 'WEBP' . str_repeat("\x00", 8),
        'heic', 'heif' => "\x00\x00\x00\x18" . 'ftypheic' . str_repeat("\x00", 8),
        'svg' => '<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>',
        default => 'not an image',
    };
}

/**
 * Simulates the array PHP builds for an uploaded file. Without explicit bytes
 * it produces content that really is the format the name claims, since the
 * importer checks.
 *
 * @return array{name: string, tmp_name: string, error: int, size: int}
 */
function makeUpload(string $name, ?string $bytes = null): array
{
    $bytes ??= makeImageBytes(strtolower(pathinfo($name, PATHINFO_EXTENSION)));
    $temporary = tempnam(sys_get_temp_dir(), 'upload');
    file_put_contents($temporary, $bytes);
    return [
        'name' => $name,
        'tmp_name' => $temporary,
        'error' => UPLOAD_ERR_OK,
        'size' => strlen($bytes),
    ];
}

$runner = new TestRunner();

$runner->suite('Workspace', function (TestRunner $t): void {
    $t->test('resolves a path inside the root', function (TestRunner $t): void {
        [$workspace, , , , $root] = makeWorkspace();
        $t->expectEqual($workspace->resolve('Notes/Ideas.md'), $root . '/Notes/Ideas.md');
    });

    $t->test('shows iCloud Drive under the name Finder uses', function (TestRunner $t): void {
        $root = sys_get_temp_dir() . '/md-icloud-' . bin2hex(random_bytes(4)) . '/com~apple~CloudDocs';
        mkdir($root, 0o777, true);
        register_shutdown_function(static function () use ($root): void {
            @rmdir($root);
            @rmdir(dirname($root));
        });
        $t->expectEqual((new Workspace($root))->name(), 'iCloud Drive');
    });

    $t->test('follows a symlinked root, which is how a synced folder is used', function (TestRunner $t): void {
        [, , , , $root] = makeWorkspace();
        $link = sys_get_temp_dir() . '/md-link-' . bin2hex(random_bytes(4));
        symlink($root, $link);
        register_shutdown_function(static fn () => @unlink($link));

        $linked = new Workspace($link);
        // The root resolves to the real folder, so paths inside it work...
        $t->expectEqual($linked->root(), $root);
        $t->expectEqual($linked->resolve('Notes/Ideas.md'), $root . '/Notes/Ideas.md');
        // ...while escaping it still fails.
        $t->expectRejects(static fn () => $linked->resolve('../outside.md', false));
    });

    $t->test('rejects parent traversal', function (TestRunner $t): void {
        [$workspace] = makeWorkspace();
        foreach (['../secret.md', '../../etc/passwd', 'Notes/../../escape.md'] as $path) {
            $t->expectRejects(static fn () => $workspace->resolve($path, false));
        }
    });

    $t->test('rejects absolute paths', function (TestRunner $t): void {
        [$workspace] = makeWorkspace();
        $t->expectRejects(static fn () => $workspace->resolve('/etc/passwd', false));
    });

    $t->test('rejects a symlink that escapes the root', function (TestRunner $t): void {
        [$workspace, , , , $root] = makeWorkspace();
        $outside = sys_get_temp_dir() . '/markdown-editor-outside-' . bin2hex(random_bytes(4));
        mkdir($outside);
        file_put_contents($outside . '/secret.md', "# Secret\n");
        symlink($outside, $root . '/link');

        $t->expectRejects(static fn () => $workspace->resolve('link/secret.md'));

        @unlink($outside . '/secret.md');
        @rmdir($outside);
    });

    $t->test('normalizes redundant separators', function (TestRunner $t): void {
        [$workspace, , , , $root] = makeWorkspace();
        $t->expectEqual($workspace->resolve('./Notes//Ideas.md'), $root . '/Notes/Ideas.md');
    });

    $t->test('reports paths relative to the root', function (TestRunner $t): void {
        [$workspace, , , , $root] = makeWorkspace();
        $t->expectEqual($workspace->relativePath($root . '/Notes/Ideas.md'), 'Notes/Ideas.md');
        $t->expectEqual($workspace->relativePath($root), '');
    });

    $t->test('classifies Markdown by extension, case insensitively', function (TestRunner $t): void {
        $t->expect(Workspace::isMarkdown('a.md'));
        $t->expect(Workspace::isMarkdown('a.MARKDOWN'));
        $t->expect(!Workspace::isMarkdown('a.txt'));
        $t->expect(!Workspace::isMarkdown('md'));
    });
});

$runner->suite('DocumentStore', function (TestRunner $t): void {
    $t->test('reads UTF-8 text', function (TestRunner $t): void {
        [, $documents] = makeWorkspace();
        $payload = $documents->read('Notes/Ideas.md');
        $t->expectEqual($payload['text'], "# Ideas\n\n- one\n");
        $t->expectEqual($payload['name'], 'Ideas.md');
        $t->expectEqual($payload['hasByteOrderMark'], false);
    });

    $t->test('round-trips a byte order mark', function (TestRunner $t): void {
        [, $documents, , , $root] = makeWorkspace();
        file_put_contents($root . '/bom.md', "\u{FEFF}# With BOM\n");

        $payload = $documents->read('bom.md');
        $t->expectEqual($payload['hasByteOrderMark'], true);
        $t->expectEqual($payload['text'], "# With BOM\n", 'the BOM is not part of the text');

        $documents->write('bom.md', $payload['text'], true);
        $t->expectEqual(file_get_contents($root . '/bom.md'), "\u{FEFF}# With BOM\n");
    });

    $t->test('writes without a BOM when the document never had one', function (TestRunner $t): void {
        [, $documents, , , $root] = makeWorkspace();
        $documents->write('Notes/Ideas.md', "# Changed\n", false);
        $t->expectEqual(file_get_contents($root . '/Notes/Ideas.md'), "# Changed\n");
    });

    $t->test('preserves multi-byte characters exactly', function (TestRunner $t): void {
        [, $documents, , , $root] = makeWorkspace();
        $text = "# Café 🎉\n\n日本語のテキスト\n";
        $documents->write('unicode.md', $text, false);
        $t->expectEqual($documents->read('unicode.md')['text'], $text);
        $t->expectEqual(file_get_contents($root . '/unicode.md'), $text);
    });

    $t->test('rejects a non-Markdown extension', function (TestRunner $t): void {
        [, $documents] = makeWorkspace();
        $t->expectRejects(static fn () => $documents->read('photo.png'), '.md');
    });

    $t->test('rejects invalid UTF-8 on read', function (TestRunner $t): void {
        [, $documents, , , $root] = makeWorkspace();
        file_put_contents($root . '/broken.md', "# Broken \xFF\xFE\n");
        $t->expectRejects(static fn () => $documents->read('broken.md'), 'UTF-8');
    });

    $t->test('reports whether a document exists', function (TestRunner $t): void {
        [, $documents] = makeWorkspace();
        $t->expect($documents->exists('Notes/Ideas.md'));
        $t->expect(!$documents->exists('Notes/Missing.md'));
        $t->expect(!$documents->exists('../outside.md'), 'an unsafe path is simply absent');
    });

    $t->test('creates an empty document but refuses to clobber', function (TestRunner $t): void {
        [, $documents, , , $root] = makeWorkspace();
        $documents->create('New.md');
        $t->expectEqual(file_get_contents($root . '/New.md'), '');
        $t->expectRejects(static fn () => $documents->create('New.md'), 'already');
    });
});

$runner->suite('FileTree', function (TestRunner $t): void {
    $t->test('lists folders before files, naturally sorted', function (TestRunner $t): void {
        [, , $tree, , $root] = makeWorkspace();
        mkdir($root . '/Zebra');
        file_put_contents($root . '/apple.md', '');
        $names = array_column($tree->contents(''), 'name');
        $t->expectEqual($names[0], 'Notes');
        $t->expectEqual($names[1], 'Zebra');
        $t->expect(in_array('apple.md', $names, true));
        $t->expect(array_search('apple.md', $names, true) > 1);
    });

    $t->test('skips hidden entries', function (TestRunner $t): void {
        [, , $tree] = makeWorkspace();
        $names = array_column($tree->contents(''), 'name');
        $t->expect(!in_array('.hidden.md', $names, true));
    });

    $t->test('flags Markdown documents', function (TestRunner $t): void {
        [, , $tree] = makeWorkspace();
        $entries = [];
        foreach ($tree->contents('') as $entry) {
            $entries[$entry['name']] = $entry;
        }
        $t->expect($entries['Readme.markdown']['isMarkdown']);
        $t->expect(!$entries['photo.png']['isMarkdown']);
        $t->expect($entries['Notes']['isDirectory']);
    });

    $t->test('walks ancestors from the root down', function (TestRunner $t): void {
        [$workspace, , $tree] = makeWorkspace();
        $ancestors = $tree->ancestors('Notes');
        $t->expectEqual(count($ancestors), 2);
        $t->expectEqual($ancestors[0]['name'], $workspace->name());
        $t->expectEqual($ancestors[0]['path'], '');
        $t->expectEqual($ancestors[1]['name'], 'Notes');
        $t->expectEqual($ancestors[1]['path'], 'Notes');
    });

    $t->test('refuses to list outside the workspace', function (TestRunner $t): void {
        [, , $tree] = makeWorkspace();
        $t->expectRejects(static fn () => $tree->contents('../'));
    });
});

$runner->suite('ImageImporter', function (TestRunner $t): void {
    /**
     * Simulates the array PHP builds for an uploaded file. Without explicit
     * bytes it produces content that really is the format the name claims,
     * since the importer now checks.
     */
    $upload = makeUpload(...);

    $t->test('copies into <stem>.assets beside the document', function (TestRunner $t) use ($upload): void {
        [, , , $images, $root] = makeWorkspace();
        $result = $images->importUpload('Notes/Ideas.md', $upload('picture.png'));
        $t->expectEqual($result['relativePath'], 'Ideas.assets/picture.png');
        $t->expect(is_file($root . '/Notes/Ideas.assets/picture.png'));
    });

    $t->test('suffixes colliding names rather than overwriting', function (TestRunner $t) use ($upload): void {
        [, , , $images] = makeWorkspace();
        $t->expectEqual(
            $images->importUpload('Notes/Ideas.md', $upload('shot.png', makeImageBytes('png') . 'one'))['relativePath'],
            'Ideas.assets/shot.png'
        );
        $t->expectEqual(
            $images->importUpload('Notes/Ideas.md', $upload('shot.png', makeImageBytes('png') . 'two'))['relativePath'],
            'Ideas.assets/shot-2.png'
        );
        $t->expectEqual(
            $images->importUpload('Notes/Ideas.md', $upload('shot.png', makeImageBytes('png') . 'three'))['relativePath'],
            'Ideas.assets/shot-3.png'
        );
    });

    $t->test('percent-encodes the reference but not the file name', function (TestRunner $t) use ($upload): void {
        [, , , $images, $root] = makeWorkspace();
        $result = $images->importUpload('Notes/Ideas.md', $upload('My Photo.png'));
        $t->expectEqual($result['relativePath'], 'Ideas.assets/My%20Photo.png');
        $t->expectEqual($result['fileName'], 'My Photo.png');
        $t->expect(is_file($root . '/Notes/Ideas.assets/My Photo.png'));
    });

    $t->test('escapes Markdown characters in alt text', function (TestRunner $t): void {
        $t->expectEqual(
            ImageImporter::markdownImageReference('a [b] c', 'x.png'),
            '![a \\[b\\] c](x.png)'
        );
    });

    $t->test('strips directory components from the uploaded name', function (TestRunner $t) use ($upload): void {
        [, , , $images] = makeWorkspace();
        $result = $images->importUpload('Notes/Ideas.md', $upload('../../evil.png'));
        $t->expectEqual($result['relativePath'], 'Ideas.assets/evil.png');
    });

    $t->test('rejects a non-image extension', function (TestRunner $t) use ($upload): void {
        [, , , $images] = makeWorkspace();
        $t->expectRejects(
            static fn () => $images->importUpload('Notes/Ideas.md', $upload('script.php')),
            'image'
        );
    });

    $t->test('rejects bytes that are not the format the name claims', function (TestRunner $t) use ($upload): void {
        [, , , $images] = makeWorkspace();
        $t->expectRejects(
            static fn () => $images->importUpload(
                'Notes/Ideas.md',
                $upload('payload.png', "<?php echo 'hi';")
            ),
            'not really a PNG'
        );
    });

    $t->test('rejects an empty upload', function (TestRunner $t) use ($upload): void {
        [, , , $images] = makeWorkspace();
        $t->expectRejects(
            static fn () => $images->importUpload('Notes/Ideas.md', $upload('empty.png', '')),
            'could not be read'
        );
    });

    $t->test('accepts every supported format when the bytes match', function (TestRunner $t) use ($upload): void {
        [, , , $images] = makeWorkspace();
        foreach (Workspace::IMAGE_EXTENSIONS as $extension) {
            $result = $images->importUpload('Notes/Ideas.md', $upload('art.' . $extension));
            $t->expectEqual($result['relativePath'], 'Ideas.assets/art.' . $extension);
        }
    });

    $t->test('accepts a static SVG', function (TestRunner $t) use ($upload): void {
        [, , , $images, $root] = makeWorkspace();
        $images->importUpload('Notes/Ideas.md', $upload('logo.svg'));
        $t->expect(is_file($root . '/Notes/Ideas.assets/logo.svg'));
    });

    $t->test('rejects an SVG that can execute', function (TestRunner $t) use ($upload): void {
        [, , , $images] = makeWorkspace();
        $hostile = [
            '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>',
            '<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"><rect/></svg>',
            '<svg xmlns="http://www.w3.org/2000/svg"><a href="javascript:alert(1)"><rect/></a></svg>',
            '<html><body>not an svg</body></html>',
        ];
        foreach ($hostile as $index => $markup) {
            $t->expectRejects(
                static fn () => $images->importUpload(
                    'Notes/Ideas.md',
                    $upload('bad-' . $index . '.svg', $markup)
                ),
                'SVG'
            );
        }
    });

    $t->test('rejects an image for a document outside the workspace', function (TestRunner $t) use ($upload): void {
        [, , , $images] = makeWorkspace();
        $t->expectRejects(
            static fn () => $images->importUpload('../Ideas.md', $upload('picture.png'))
        );
    });
});

$runner->suite('FileManager', function (TestRunner $runner): void {
    $upload = makeUpload(...);

    $runner->test('creates a folder and lists it', function (TestRunner $t): void {
        [, , $tree, , $root, $files] = makeWorkspace();

        $entry = $files->createFolder('', 'Drafts');
        $t->expectEqual($entry['path'], 'Drafts');
        $t->expect($entry['isDirectory'], 'the new entry is a folder');
        $t->expect(is_dir($root . '/Drafts'), 'the folder is on disk');

        $names = array_column($tree->contents(''), 'name');
        $t->expect(in_array('Drafts', $names, true), 'the folder appears in the sidebar');
    });

    $runner->test('creates a folder inside another folder', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();
        $entry = $files->createFolder('Notes', '2026');
        $t->expectEqual($entry['path'], 'Notes/2026');
        $t->expectEqual($entry['parent'], 'Notes');
        $t->expect(is_dir($root . '/Notes/2026'), 'the nested folder is on disk');
    });

    $runner->test('refuses names that would not be a single visible item', function (TestRunner $t): void {
        [, , , , , $files] = makeWorkspace();

        $t->expectRejects(static fn () => $files->createFolder('', 'a/b'), 'slash');
        $t->expectRejects(static fn () => $files->createFolder('', 'a\\b'), 'slash');
        $t->expectRejects(static fn () => $files->createFolder('', '..'), 'reserved');
        $t->expectRejects(static fn () => $files->createFolder('', '.'), 'reserved');
        $t->expectRejects(static fn () => $files->createFolder('', '.secret'), 'period');
        $t->expectRejects(static fn () => $files->createFolder('', "bad\nname"), 'not allowed');
        $t->expectRejects(static fn () => $files->createFolder('', '   '), 'Enter a name');
        $t->expectRejects(static fn () => $files->createFolder('', str_repeat('x', 256)), 'too long');
    });

    $runner->test('refuses to create over something that is already there', function (TestRunner $t): void {
        [, , , , , $files] = makeWorkspace();
        $t->expectRejects(static fn () => $files->createFolder('', 'Notes'), 'already there');
    });

    $runner->test('refuses to create outside the workspace', function (TestRunner $t): void {
        [, , , , , $files] = makeWorkspace();
        $t->expectRejects(static fn () => $files->createFolder('..', 'Escaped'));
        $t->expectRejects(static fn () => $files->createFolder('/tmp', 'Escaped'));
    });

    $runner->test('creates a document and supplies a missing extension', function (TestRunner $t): void {
        [, $documents, , , $root, $files] = makeWorkspace();

        $entry = $files->createDocument('Notes', 'Shopping');
        $t->expectEqual($entry['name'], 'Shopping.md');
        $t->expect($entry['isMarkdown'], 'the new document reads as Markdown');
        $t->expectEqual(file_get_contents($root . '/Notes/Shopping.md'), '');
        $t->expectEqual($documents->read('Notes/Shopping.md')['text'], '');
    });

    $runner->test('keeps an extension that was typed', function (TestRunner $t): void {
        [, , , , , $files] = makeWorkspace();
        $t->expectEqual($files->createDocument('', 'Log.markdown')['name'], 'Log.markdown');
    });

    $runner->test('renames a document', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();

        $entry = $files->rename('Notes/Ideas.md', 'Better Ideas.md');
        $t->expectEqual($entry['path'], 'Notes/Better Ideas.md');
        $t->expect(!file_exists($root . '/Notes/Ideas.md'), 'the old name is gone');
        $t->expectEqual(file_get_contents($root . '/Notes/Better Ideas.md'), "# Ideas\n\n- one\n");
    });

    $runner->test('carries the extension through a rename that omits one', function (TestRunner $t): void {
        [, , , , , $files] = makeWorkspace();
        $t->expectEqual($files->rename('Notes/Ideas.md', 'Plans')['name'], 'Plans.md');
        $t->expectEqual($files->rename('Readme.markdown', 'Guide')['name'], 'Guide.markdown');
    });

    $runner->test('refuses a rename that would orphan a document', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();
        $t->expectRejects(
            static fn () => $files->rename('Notes/Ideas.md', 'Ideas.txt'),
            '.md or .markdown'
        );
        $t->expect(is_file($root . '/Notes/Ideas.md'), 'the document is untouched');
    });

    $runner->test('renames a folder without touching its contents', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();
        $entry = $files->rename('Notes', 'Archive');
        $t->expectEqual($entry['path'], 'Archive');
        $t->expectEqual(file_get_contents($root . '/Archive/Ideas.md'), "# Ideas\n\n- one\n");
    });

    $runner->test('refuses a rename onto an existing name', function (TestRunner $t): void {
        [, , , , , $files] = makeWorkspace();
        $files->createDocument('Notes', 'Taken.md');
        $t->expectRejects(
            static fn () => $files->rename('Notes/Ideas.md', 'Taken.md'),
            'already there'
        );
    });

    $runner->test('a rename to the same name is a no-op', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();
        $t->expectEqual($files->rename('Notes/Ideas.md', 'Ideas.md')['path'], 'Notes/Ideas.md');
        $t->expect(is_file($root . '/Notes/Ideas.md'), 'the document survives');
    });

    $runner->test('renaming a document takes its images with it', function (TestRunner $t) use ($upload): void {
        [, , , $images, $root, $files] = makeWorkspace();

        $imported = $images->importUpload('Notes/Ideas.md', $upload('photo.png'));
        file_put_contents(
            $root . '/Notes/Ideas.md',
            "# Ideas\n\n" . $imported['markdownReference'] . "\n"
        );

        $entry = $files->rename('Notes/Ideas.md', 'Trip Notes.md');

        $t->expectEqual($entry['name'], 'Trip Notes.md');
        $t->expect(!is_dir($root . '/Notes/Ideas.assets'), 'the old assets folder is gone');
        $t->expect(is_file($root . '/Notes/Trip%20Notes.assets/photo.png') === false, 'the folder is not encoded on disk');
        $t->expect(is_file($root . '/Notes/Trip Notes.assets/photo.png'), 'the image moved');

        $text = file_get_contents($root . '/Notes/Trip Notes.md');
        $t->expect(
            str_contains($text, '(Trip%20Notes.assets/photo.png)'),
            'the reference points at the new folder, still encoded: ' . $text
        );
    });

    $runner->test('rewrites an unencoded reference too', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();
        mkdir($root . '/Notes/Ideas.assets');
        file_put_contents($root . '/Notes/Ideas.assets/shot.png', 'x');
        file_put_contents(
            $root . '/Notes/Ideas.md',
            "![a](Ideas.assets/shot.png)\n"
        );

        $files->rename('Notes/Ideas.md', 'Plans.md');

        $t->expectEqual(
            file_get_contents($root . '/Notes/Plans.md'),
            "![a](Plans.assets/shot.png)\n"
        );
    });

    $runner->test('refuses a rename when the images folder cannot follow', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();
        mkdir($root . '/Notes/Ideas.assets');
        mkdir($root . '/Notes/Plans.assets');

        $t->expectRejects(static fn () => $files->rename('Notes/Ideas.md', 'Plans.md'), 'already there');
        $t->expect(is_file($root . '/Notes/Ideas.md'), 'the document did not move');
        $t->expect(is_dir($root . '/Notes/Ideas.assets'), 'the images did not move');
    });

    $runner->test('refuses to rename the workspace itself', function (TestRunner $t): void {
        [, , , , , $files] = makeWorkspace();
        $t->expectRejects(static fn () => $files->rename('', 'Elsewhere'), 'workspace folder itself');
    });

    $runner->test('moves a document into another folder', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();

        $entry = $files->move('Readme.markdown', 'Notes');
        $t->expectEqual($entry['path'], 'Notes/Readme.markdown');
        $t->expect(!file_exists($root . '/Readme.markdown'), 'the original is gone');
        $t->expectEqual(file_get_contents($root . '/Notes/Readme.markdown'), "# Readme\n");
    });

    $runner->test('moving a document takes its images with it', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();
        mkdir($root . '/Readme.assets');
        file_put_contents($root . '/Readme.assets/shot.png', 'x');

        $files->move('Readme.markdown', 'Notes');

        $t->expect(is_file($root . '/Notes/Readme.assets/shot.png'), 'the images followed');
        $t->expect(!is_dir($root . '/Readme.assets'), 'nothing was left behind');
    });

    $runner->test('moving into the same folder is a no-op', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();
        $t->expectEqual($files->move('Notes/Ideas.md', 'Notes')['path'], 'Notes/Ideas.md');
        $t->expect(is_file($root . '/Notes/Ideas.md'), 'the document survives');
    });

    $runner->test('refuses to move a folder inside itself', function (TestRunner $t): void {
        [, , , , , $files] = makeWorkspace();
        $files->createFolder('Notes', 'Inner');
        $t->expectRejects(static fn () => $files->move('Notes', 'Notes/Inner'), 'inside itself');
        $t->expectRejects(static fn () => $files->move('Notes', 'Notes'), 'inside itself');
    });

    $runner->test('refuses to move onto an existing name', function (TestRunner $t): void {
        [, , , , , $files] = makeWorkspace();
        $files->createDocument('Notes', 'Readme.markdown');
        $t->expectRejects(static fn () => $files->move('Readme.markdown', 'Notes'), 'already there');
    });

    $runner->test('duplicates a document beside itself', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();

        $first = $files->duplicate('Notes/Ideas.md');
        $t->expectEqual($first['path'], 'Notes/Ideas-2.md');
        $t->expectEqual(file_get_contents($root . '/Notes/Ideas-2.md'), "# Ideas\n\n- one\n");

        $t->expectEqual($files->duplicate('Notes/Ideas.md')['name'], 'Ideas-3.md');
    });

    $runner->test('duplicates a folder and everything in it', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();
        $entry = $files->duplicate('Notes');
        $t->expectEqual($entry['path'], 'Notes-2');
        $t->expectEqual(file_get_contents($root . '/Notes-2/Ideas.md'), "# Ideas\n\n- one\n");
    });

    $runner->test('a duplicate gets its own copy of the images', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();
        mkdir($root . '/Notes/Ideas.assets');
        file_put_contents($root . '/Notes/Ideas.assets/shot.png', 'x');
        file_put_contents($root . '/Notes/Ideas.md', "![a](Ideas.assets/shot.png)\n");

        $files->duplicate('Notes/Ideas.md');

        $t->expect(is_file($root . '/Notes/Ideas.assets/shot.png'), 'the original keeps its images');
        $t->expect(is_file($root . '/Notes/Ideas-2.assets/shot.png'), 'the copy has its own');
        $t->expectEqual(
            file_get_contents($root . '/Notes/Ideas-2.md'),
            "![a](Ideas-2.assets/shot.png)\n"
        );
    });

    $runner->test('deletes a document', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();
        $entry = $files->delete('Notes/Ideas.md');
        $t->expect($entry['deleted'], 'the response says so');
        $t->expectEqual($entry['name'], 'Ideas.md');
        $t->expect(!file_exists($root . '/Notes/Ideas.md'), 'the document is gone');
    });

    $runner->test('deletes a folder and its contents', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();
        $files->createFolder('Notes', 'Inner');
        $files->createDocument('Notes/Inner', 'Deep.md');

        $files->delete('Notes');
        $t->expect(!file_exists($root . '/Notes'), 'the folder is gone');
    });

    $runner->test('acts on a symbolic link, never on what it points at', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();
        symlink($root . '/Notes', $root . '/Shortcut');

        // Renaming must move the link. Following it would rename the real
        // folder and leave the link dangling.
        $files->rename('Shortcut', 'Pointer');
        $t->expect(is_link($root . '/Pointer'), 'the link was renamed');
        $t->expect(is_dir($root . '/Notes'), 'the folder it points at is untouched');
        $t->expect(is_file($root . '/Notes/Ideas.md'), 'and still holds its documents');

        // Deleting must unlink it, not empty the folder behind it.
        $files->delete('Pointer');
        $t->expect(!is_link($root . '/Pointer'), 'the link is gone');
        $t->expect(is_file($root . '/Notes/Ideas.md'), 'the real documents survive');
    });

    $runner->test('deletes a link that points outside without following it', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();
        $outside = sys_get_temp_dir() . '/markdown-editor-outside-' . bin2hex(random_bytes(4));
        mkdir($outside);
        file_put_contents($outside . '/keepme.md', "# Keep\n");
        symlink($outside, $root . '/Linked');

        $files->delete('Linked');

        $t->expect(!is_link($root . '/Linked'), 'the link is gone');
        $t->expect(is_file($outside . '/keepme.md'), 'what it pointed at is untouched');
        removeTree($outside);
    });

    $runner->test('refuses to delete the workspace itself', function (TestRunner $t): void {
        [, , , , $root, $files] = makeWorkspace();
        $t->expectRejects(static fn () => $files->delete(''), 'workspace folder itself');
        $t->expectRejects(static fn () => $files->delete('.'), 'workspace folder itself');
        $t->expect(is_dir($root), 'the workspace survives');
    });

    $runner->test('refuses to touch anything outside the workspace', function (TestRunner $t): void {
        [, , , , , $files] = makeWorkspace();
        $t->expectRejects(static fn () => $files->delete('../secrets.md'));
        $t->expectRejects(static fn () => $files->rename('../secrets.md', 'x.md'));
        $t->expectRejects(static fn () => $files->move('Notes/Ideas.md', '..'));
        $t->expectRejects(static fn () => $files->duplicate('/etc/hosts'));
    });
});

$runner->suite('Default workspace', function (TestRunner $runner): void {
    $runner->test('creates the folder and its starter documents on first run', function (TestRunner $t): void {
        $root = sys_get_temp_dir() . '/markdown-editor-first-run-' . bin2hex(random_bytes(6));
        $t->expect(!file_exists($root), 'the folder does not exist yet');

        $workspace = Workspace::prepare($root);

        $t->expectEqual($workspace->root(), realpath($root));
        $t->expect(is_file($root . '/Welcome.md'), 'the welcome document is there');
        $t->expect(is_file($root . '/Notes/Ideas.md'), 'the nested starter document is there');

        // A second open must not put the starter documents back.
        unlink($root . '/Welcome.md');
        Workspace::prepare($root);
        $t->expect(!file_exists($root . '/Welcome.md'), 'an existing folder is left alone');

        removeTree($root);
    });

    $runner->test('names the folder kirupaMarkdown by default', function (TestRunner $t): void {
        $previous = getenv('MARKDOWN_EDITOR_WORKSPACE');
        putenv('MARKDOWN_EDITOR_WORKSPACE');

        $t->expectEqual(basename(Workspace::defaultRoot()), 'kirupaMarkdown');
        $t->expectEqual(
            Workspace::defaultRoot(),
            rtrim(getenv('HOME'), '/') . '/kirupaMarkdown'
        );

        if ($previous !== false) {
            putenv('MARKDOWN_EDITOR_WORKSPACE=' . $previous);
        }
    });

    $runner->test('an explicit workspace wins', function (TestRunner $t): void {
        $previous = getenv('MARKDOWN_EDITOR_WORKSPACE');
        $chosen = sys_get_temp_dir() . '/markdown-editor-chosen-' . bin2hex(random_bytes(4));
        putenv('MARKDOWN_EDITOR_WORKSPACE=' . $chosen . '/');

        $t->expectEqual(Workspace::defaultRoot(), $chosen);
        $t->expectEqual(Workspace::prepare()->root(), realpath($chosen));

        removeTree($chosen);
        putenv($previous === false
            ? 'MARKDOWN_EDITOR_WORKSPACE'
            : 'MARKDOWN_EDITOR_WORKSPACE=' . $previous);
    });

    $runner->test('falls back inside the web root when there is no usable home', function (TestRunner $t): void {
        $previousWorkspace = getenv('MARKDOWN_EDITOR_WORKSPACE');
        $previousHome = getenv('HOME');
        putenv('MARKDOWN_EDITOR_WORKSPACE');
        putenv('HOME');
        $previousServerHome = $_SERVER['HOME'] ?? null;
        unset($_SERVER['HOME']);

        // A web server account often has no home directory at all, so the
        // fallback has to land somewhere the process can definitely write.
        $t->expectEqual(
            Workspace::defaultRoot(),
            dirname(__DIR__, 2) . '/kirupaMarkdown'
        );

        if ($previousServerHome !== null) {
            $_SERVER['HOME'] = $previousServerHome;
        }
        putenv($previousHome === false ? 'HOME' : 'HOME=' . $previousHome);
        putenv($previousWorkspace === false
            ? 'MARKDOWN_EDITOR_WORKSPACE'
            : 'MARKDOWN_EDITOR_WORKSPACE=' . $previousWorkspace);
    });

    $runner->test('ignores a home directory it cannot write to', function (TestRunner $t): void {
        $previousWorkspace = getenv('MARKDOWN_EDITOR_WORKSPACE');
        $previousHome = getenv('HOME');
        putenv('MARKDOWN_EDITOR_WORKSPACE');

        $home = sys_get_temp_dir() . '/markdown-editor-readonly-home-' . bin2hex(random_bytes(4));
        mkdir($home, 0o500, true);
        putenv('HOME=' . $home);

        $t->expectEqual(
            Workspace::defaultRoot(),
            dirname(__DIR__, 2) . '/kirupaMarkdown'
        );

        chmod($home, 0o755);
        removeTree($home);
        putenv($previousHome === false ? 'HOME' : 'HOME=' . $previousHome);
        putenv($previousWorkspace === false
            ? 'MARKDOWN_EDITOR_WORKSPACE'
            : 'MARKDOWN_EDITOR_WORKSPACE=' . $previousWorkspace);
    });
});

exit($runner->run());
