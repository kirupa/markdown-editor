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
}
