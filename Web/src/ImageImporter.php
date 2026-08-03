<?php

declare(strict_types=1);

namespace MarkdownEditor;

/**
 * Copies an uploaded image next to its document and returns the Markdown
 * reference to insert.
 *
 * Mirrors macOS/Sources/MarkdownEditorCore/MarkdownImageImporter.swift so both
 * versions of the editor produce byte-identical references and lay assets out
 * the same way (PRD I-1 through I-18). A document folder written by one can be
 * opened by the other with every image still resolving.
 */
final class ImageImporter
{
    /**
     * Characters left unescaped when percent-encoding a path component, per
     * RFC 3986's unreserved set (PRD I-9). Matching Swift's
     * `.urlPathAllowed` here would leave `(` and `)` alone, which would break
     * the surrounding `![](...)` syntax.
     */
    private const UNRESERVED = '/[^A-Za-z0-9\-._~]/';

    public function __construct(private readonly Workspace $workspace)
    {
    }

    /**
     * @param array{name: string, tmp_name: string, error: int, size: int} $upload
     * @return array<string, mixed>
     */
    public function importUpload(string $documentPath, array $upload): array
    {
        $this->assertUploadSucceeded($upload);

        $originalName = basename(str_replace('\\', '/', $upload['name']));
        $extension = strtolower(pathinfo($originalName, PATHINFO_EXTENSION));
        if (!Workspace::isSupportedImage($originalName)) {
            throw new WorkspaceError(
                $extension === ''
                    ? 'The selected file is not a supported image.'
                    : 'The selected .' . $extension . ' file is not a supported image.',
                'Supported formats are ' . implode(', ', Workspace::IMAGE_EXTENSIONS) . '.'
            );
        }

        $documentAbsolute = $this->workspace->resolve($documentPath);
        if (!is_file($documentAbsolute)) {
            throw new WorkspaceError(
                'Save the Markdown document before adding an image.',
                'Images are stored beside the document, so it needs a location first.'
            );
        }

        // The extension is only what the client claimed. Anything landing in a
        // web root has to be checked against its actual bytes (PRD WI-12).
        $this->assertImageContent($upload['tmp_name'], $extension, $originalName);

        $assetsDirectory = $this->prepareAssetsDirectory($documentAbsolute);
        $destination = $this->nextAvailableDestination($assetsDirectory, $originalName);

        if (!@move_uploaded_file($upload['tmp_name'], $destination)
            // Fall back to a plain copy so the same code path is testable
            // without a real multipart request.
            && !@copy($upload['tmp_name'], $destination)
        ) {
            throw new WorkspaceError(
                'The image could not be copied: ' . $originalName,
                'Check that the web server can write to '
                    . basename($assetsDirectory) . '.'
            );
        }
        @chmod($destination, 0o644);

        $relativePath = $this->encodedRelativePath(
            basename($assetsDirectory),
            basename($destination)
        );
        $altText = pathinfo($originalName, PATHINFO_FILENAME);

        return [
            'relativePath' => $relativePath,
            'markdownReference' => self::markdownImageReference($altText, $relativePath),
            'fileName' => basename($destination),
            'path' => $this->workspace->relativePath($destination),
        ];
    }

    /** `![alt](path)` with the alt text escaped so a filename cannot break it (I-10). */
    public static function markdownImageReference(string $altText, string $relativePath): string
    {
        $escaped = str_replace(
            ['\\', '[', ']'],
            ['\\\\', '\\[', '\\]'],
            $altText
        );
        return '![' . $escaped . '](' . $relativePath . ')';
    }

    /** `<document-stem>.assets` beside the document (I-1). */
    public static function assetsDirectoryName(string $documentPath): string
    {
        return pathinfo($documentPath, PATHINFO_FILENAME) . '.assets';
    }

    /**
     * Leading bytes that identify each raster format, keyed by the extension
     * family they belong to.
     *
     * `getimagesize()` cannot read HEIC and is not guaranteed to be built with
     * WEBP support, so the check is done directly rather than half of it being
     * delegated to a function whose coverage varies by host.
     *
     * @var array<string, list<string>>
     */
    private const SIGNATURES = [
        'bmp' => ['BM'],
        'gif' => ['GIF87a', 'GIF89a'],
        'jpeg' => ["\xFF\xD8\xFF"],
        'png' => ["\x89PNG\r\n\x1A\n"],
        'tiff' => ["II\x2A\x00", "MM\x00\x2A"],
    ];

    /** Extensions that are spellings of the same format. */
    private const FAMILIES = [
        'bmp' => 'bmp',
        'gif' => 'gif',
        'jpg' => 'jpeg',
        'jpeg' => 'jpeg',
        'png' => 'png',
        'tif' => 'tiff',
        'tiff' => 'tiff',
        'heic' => 'heif',
        'heif' => 'heif',
        'webp' => 'webp',
        'svg' => 'svg',
    ];

    /**
     * Refuses a file whose contents are not the image type its name claims.
     *
     * Without this, the extension allowlist is only as trustworthy as the
     * client, and the assets folder sits inside the document root.
     */
    private function assertImageContent(string $path, string $extension, string $name): void
    {
        $family = self::FAMILIES[$extension] ?? '';
        $handle = @fopen($path, 'rb');
        $head = $handle === false ? false : fread($handle, 4096);
        if ($handle !== false) {
            fclose($handle);
        }
        if ($head === false || $head === '') {
            throw new WorkspaceError(
                'The image could not be read: ' . $name,
                'It may be empty or the upload may have been interrupted.'
            );
        }

        $matches = match ($family) {
            'heif' => substr($head, 4, 4) === 'ftyp',
            'webp' => str_starts_with($head, 'RIFF') && substr($head, 8, 4) === 'WEBP',
            'svg' => self::isSafeSvg(file_get_contents($path) ?: ''),
            default => self::matchesSignature($head, $family),
        };

        if (!$matches) {
            throw new WorkspaceError(
                $family === 'svg'
                    ? 'That SVG contains scripting and was not imported: ' . $name
                    : 'That file is not really a ' . strtoupper($extension) . ' image: ' . $name,
                $family === 'svg'
                    ? 'Only static SVG artwork can be added to a document.'
                    : 'Its contents do not match its file extension.'
            );
        }
    }

    private static function matchesSignature(string $head, string $family): bool
    {
        foreach (self::SIGNATURES[$family] ?? [] as $signature) {
            if (str_starts_with($head, $signature)) {
                return true;
            }
        }
        return false;
    }

    /**
     * An SVG is markup, and the browser runs it. It must parse as XML with an
     * `<svg>` root and carry nothing that executes.
     */
    private static function isSafeSvg(string $contents): bool
    {
        if ($contents === '') {
            return false;
        }

        $previous = libxml_use_internal_errors(true);
        $document = new \DOMDocument();
        $parsed = $document->loadXML($contents, LIBXML_NONET | LIBXML_NOENT);
        libxml_clear_errors();
        libxml_use_internal_errors($previous);

        if (!$parsed || $document->documentElement === null) {
            return false;
        }
        if (strtolower($document->documentElement->localName) !== 'svg') {
            return false;
        }

        foreach ((new \DOMXPath($document))->query('//*') ?: [] as $element) {
            if (strtolower($element->localName) === 'script') {
                return false;
            }
            foreach ($element->attributes ?? [] as $attribute) {
                $attributeName = strtolower($attribute->name);
                if (str_starts_with($attributeName, 'on')) {
                    return false;
                }
                $value = strtolower(preg_replace('/\s+/', '', $attribute->value) ?? '');
                if (str_contains($value, 'javascript:') || str_contains($value, 'data:text/html')) {
                    return false;
                }
            }
        }

        return true;
    }

    /**
     * Percent-encodes each component and joins with a literal `/` (I-9).
     * The separator is added after encoding so it survives.
     */
    public function encodedRelativePath(string $directoryName, string $fileName): string
    {
        return self::encodeComponent($directoryName) . '/' . self::encodeComponent($fileName);
    }

    public static function encodeComponent(string $component): string
    {
        $encoded = preg_replace_callback(
            self::UNRESERVED,
            static fn (array $match): string => sprintf('%%%02X', ord($match[0])),
            $component
        );
        if ($encoded === null) {
            throw new WorkspaceError(
                'The relative image path could not be encoded: ' . $component
            );
        }
        return $encoded;
    }

    /**
     * Creates the assets folder if needed and refuses anything that is not a
     * real subdirectory of the document's own folder.
     *
     * The symlink check is the reason this is a separate step: without it, a
     * `post.assets` symlink pointing elsewhere would let an upload write
     * outside the workspace entirely (I-16, I-18).
     */
    private function prepareAssetsDirectory(string $documentAbsolute): string
    {
        $documentDirectory = dirname($documentAbsolute);
        $name = self::assetsDirectoryName($documentAbsolute);
        if ($name === '.assets') {
            throw new WorkspaceError(
                'Images can only be added to a document with a filename.'
            );
        }
        $assetsDirectory = $documentDirectory . DIRECTORY_SEPARATOR . $name;

        if (file_exists($assetsDirectory) || is_link($assetsDirectory)) {
            if (is_link($assetsDirectory) || !is_dir($assetsDirectory)) {
                throw new WorkspaceError(
                    'The assets location is not a regular folder beside the document: '
                        . $name
                );
            }
        } elseif (!@mkdir($assetsDirectory, 0o755, true) && !is_dir($assetsDirectory)) {
            throw new WorkspaceError(
                'The assets folder could not be created: ' . $name,
                'Check that the web server can write to '
                    . basename($documentDirectory) . '.'
            );
        }

        $resolvedAssets = realpath($assetsDirectory);
        $resolvedDocumentDirectory = realpath($documentDirectory);
        if ($resolvedAssets === false || $resolvedDocumentDirectory === false
            || $resolvedAssets !== $resolvedDocumentDirectory . DIRECTORY_SEPARATOR . $name
        ) {
            throw new WorkspaceError(
                'The assets location is not a regular folder beside the document: ' . $name
            );
        }

        return $resolvedAssets;
    }

    /**
     * First free name, appending `-2`, `-3`, … before the extension (I-7).
     * Nothing is ever overwritten.
     */
    public function nextAvailableDestination(string $directory, string $fileName): string
    {
        $candidate = $directory . DIRECTORY_SEPARATOR . $fileName;
        if (!file_exists($candidate) && !is_link($candidate)) {
            return $candidate;
        }

        $stem = pathinfo($fileName, PATHINFO_FILENAME);
        $extension = pathinfo($fileName, PATHINFO_EXTENSION);

        for ($suffix = 2; ; $suffix++) {
            $name = $extension === ''
                ? $stem . '-' . $suffix
                : $stem . '-' . $suffix . '.' . $extension;
            $candidate = $directory . DIRECTORY_SEPARATOR . $name;
            if (!file_exists($candidate) && !is_link($candidate)) {
                return $candidate;
            }
        }
    }

    /** @param array{name: string, tmp_name: string, error: int, size: int} $upload */
    private function assertUploadSucceeded(array $upload): void
    {
        $message = match ($upload['error']) {
            UPLOAD_ERR_OK => null,
            UPLOAD_ERR_INI_SIZE, UPLOAD_ERR_FORM_SIZE => 'The image is larger than the server allows.',
            UPLOAD_ERR_PARTIAL => 'The image was only partially uploaded.',
            UPLOAD_ERR_NO_FILE => 'No image was selected.',
            UPLOAD_ERR_NO_TMP_DIR => 'The server has no temporary folder for uploads.',
            UPLOAD_ERR_CANT_WRITE => 'The server could not write the uploaded image to disk.',
            UPLOAD_ERR_EXTENSION => 'A server extension blocked the upload.',
            default => 'The image could not be uploaded.',
        };

        if ($message !== null) {
            throw new WorkspaceError(
                $message,
                'Check upload_max_filesize and post_max_size in php.ini, then try again.'
            );
        }

        if (!is_file($upload['tmp_name'])) {
            throw new WorkspaceError('The uploaded image could not be found on the server.');
        }
    }
}
