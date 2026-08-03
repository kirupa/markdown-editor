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
use MarkdownEditor\FileTree;
use MarkdownEditor\ImageImporter;
use MarkdownEditor\Workspace;

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

    register_shutdown_function(static function () use ($root): void {
        $items = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS),
            RecursiveIteratorIterator::CHILD_FIRST
        );
        foreach ($items as $item) {
            $item->isDir() ? @rmdir($item->getPathname()) : @unlink($item->getPathname());
        }
        @rmdir($root);
    });

    $workspace = new Workspace($root);
    return [
        $workspace,
        new DocumentStore($workspace),
        new FileTree($workspace),
        new ImageImporter($workspace),
        // The resolved root, since macOS reports /var as /private/var.
        $workspace->root(),
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

$runner = new TestRunner();

$runner->suite('Workspace', function (TestRunner $t): void {
    $t->test('resolves a path inside the root', function (TestRunner $t): void {
        [$workspace, , , , $root] = makeWorkspace();
        $t->expectEqual($workspace->resolve('Notes/Ideas.md'), $root . '/Notes/Ideas.md');
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
    $upload = static function (string $name, ?string $bytes = null): array {
        $bytes ??= makeImageBytes(strtolower(pathinfo($name, PATHINFO_EXTENSION)));
        $temporary = tempnam(sys_get_temp_dir(), 'upload');
        file_put_contents($temporary, $bytes);
        return [
            'name' => $name,
            'tmp_name' => $temporary,
            'error' => UPLOAD_ERR_OK,
            'size' => strlen($bytes),
        ];
    };

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

exit($runner->run());
