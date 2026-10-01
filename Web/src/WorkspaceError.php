<?php

declare(strict_types=1);

namespace MarkdownEditor;

/**
 * An error with a message meant for the user.
 *
 * The macOS app surfaces every file and image failure through
 * `NSError`'s localized description and recovery suggestion (PRD G-6). This
 * carries the same two strings so the web UI can present them the same way,
 * instead of leaking a PHP warning or failing silently.
 */
class WorkspaceError extends \RuntimeException
{
    public function __construct(
        string $message,
        private readonly string $recoverySuggestion = '',
        private readonly int $status = 400
    ) {
        parent::__construct($message);
    }

    public function recoverySuggestion(): string
    {
        return $this->recoverySuggestion;
    }

    public function status(): int
    {
        return $this->status;
    }

    /** @return array{error: string, recovery?: string} */
    public function toPayload(): array
    {
        $payload = ['error' => $this->getMessage()];
        if ($this->recoverySuggestion !== '') {
            $payload['recovery'] = $this->recoverySuggestion;
        }
        return $payload;
    }

    /**
     * A critique that could not be run, or could not be understood.
     *
     * **424, not 502**, and not because 424 is a better description — 502 is.
     * A CDN replaces a 5xx body from the origin with its own error page, so a
     * carefully worded explanation of a bad key comes out of Cloudflare as the
     * string "error code: 502" and nothing else. This app promises that nothing
     * fails silently ([WG-4]), and a status whose body is thrown away in transit
     * cannot keep that promise.
     *
     * 424 Failed Dependency is the closest honest 4xx: the request was fine,
     * and the thing it depended on was not. Being 4xx, it reaches the browser
     * with its body intact.
     */
    public static function critique(string $message, string $recovery = ''): self
    {
        return new self($message, $recovery, 424);
    }
}
