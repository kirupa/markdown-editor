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
     * 502 rather than 400 or 500: nothing is wrong with what the browser
     * asked for, and nothing is wrong with this server either. The failure is
     * upstream, and saying so is the difference between "try again" and "fix
     * your document".
     */
    public static function critique(string $message, string $recovery = ''): self
    {
        return new self($message, $recovery, 502);
    }
}
