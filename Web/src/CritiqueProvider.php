<?php

declare(strict_types=1);

namespace MarkdownEditor;

/**
 * Port of Shared/Sources/MarkdownEditorCore/CritiqueProvider.swift.
 *
 * Where a critique comes from, and the shape each provider wants the same
 * request in.
 *
 * The Mac's fourth provider -- a model already installed on the reader's
 * machine, needing no key -- has no equivalent here and is deliberately
 * absent. A server has no Copilot CLI, and pretending otherwise would put an
 * option in a menu that could never work.
 */
final class CritiqueProvider
{
    public const OPENAI = 'openAI';
    public const ANTHROPIC = 'anthropic';
    public const GEMINI = 'gemini';

    public const ALL = [self::OPENAI, self::ANTHROPIC, self::GEMINI];

    public function __construct(public readonly string $id)
    {
    }

    public static function isKnown(string $id): bool
    {
        return in_array($id, self::ALL, true);
    }

    public function title(): string
    {
        return match ($this->id) {
            self::OPENAI => 'OpenAI',
            self::ANTHROPIC => 'Anthropic',
            self::GEMINI => 'Google Gemini',
            default => $this->id,
        };
    }

    /**
     * The models offered, cheapest first.
     *
     * A critique is one request returning a page of JSON. It wants a model
     * that follows a schema and reads carefully; it does not want the
     * reasoning tier, which costs many times more for work that is not much
     * better at this.
     */
    public function models(): array
    {
        return match ($this->id) {
            self::OPENAI => ['gpt-4o-mini', 'gpt-4o'],
            self::ANTHROPIC => ['claude-3-5-haiku-latest', 'claude-3-5-sonnet-latest'],
            self::GEMINI => ['gemini-1.5-flash', 'gemini-1.5-pro'],
            default => [],
        };
    }

    public function defaultModel(): string
    {
        return $this->models()[0] ?? '';
    }

    /** The environment variable each provider's key is read from. */
    public function keyVariable(): string
    {
        return match ($this->id) {
            self::OPENAI => 'OPENAI_API_KEY',
            self::ANTHROPIC => 'ANTHROPIC_API_KEY',
            self::GEMINI => 'GEMINI_API_KEY',
            default => '',
        };
    }

    public function endpoint(string $model): string
    {
        return match ($this->id) {
            self::OPENAI => $this->base('https://api.openai.com') . '/v1/chat/completions',
            self::ANTHROPIC => $this->base('https://api.anthropic.com') . '/v1/messages',
            self::GEMINI => $this->base('https://generativelanguage.googleapis.com')
                . '/v1beta/models/' . rawurlencode($model) . ':generateContent',
            default => '',
        };
    }

    /**
     * Where to send the request, when it is not the provider's own host.
     *
     * `MDE_CRITIQUE_BASE_URL` exists because the OpenAI request shape is spoken
     * by a good deal more than OpenAI: Azure's deployment endpoints, OpenRouter,
     * a corporate proxy, and a model running on the same machine all take the
     * same body at a different host. Hard-coding the host would mean the only
     * way to use any of them is to edit this file.
     *
     * It is also how this build is exercised end to end without spending a
     * request on a live account.
     */
    private function base(string $default): string
    {
        $override = getenv('MDE_CRITIQUE_BASE_URL');
        if (!is_string($override) || trim($override) === '') {
            $override = $_SERVER['MDE_CRITIQUE_BASE_URL'] ?? '';
        }
        $override = is_string($override) ? trim($override) : '';
        return $override === '' ? $default : rtrim($override, '/');
    }

    /**
     * Headers, with the key where each provider expects it.
     *
     * They disagree: OpenAI wants a bearer token, Anthropic a bare header plus
     * a dated version, Google a header of its own. Getting one wrong reads as
     * an authentication failure rather than a mistake in the request, so each
     * is stated here once and checked.
     *
     * @return list<string>
     */
    public function headers(string $apiKey): array
    {
        return match ($this->id) {
            self::OPENAI => [
                'Content-Type: application/json',
                'Authorization: Bearer ' . $apiKey,
            ],
            self::ANTHROPIC => [
                'Content-Type: application/json',
                'x-api-key: ' . $apiKey,
                'anthropic-version: 2023-06-01',
            ],
            self::GEMINI => [
                'Content-Type: application/json',
                'x-goog-api-key: ' . $apiKey,
            ],
            default => [],
        };
    }

    /** The body, as each provider's shape of the same request. */
    public function body(string $prompt, string $model): array
    {
        return match ($this->id) {
            self::OPENAI => [
                'model' => $model,
                'messages' => [['role' => 'user', 'content' => $prompt]],
                // Low, not zero: the critique is a judgement, and a model
                // pinned to zero repeats the same three observations about
                // every draft.
                'temperature' => 0.2,
            ],
            self::ANTHROPIC => [
                'model' => $model,
                // Required by this API, unlike the other two. A critique of a
                // long draft runs to a few thousand tokens of JSON.
                'max_tokens' => 4096,
                'temperature' => 0.2,
                'messages' => [['role' => 'user', 'content' => $prompt]],
            ],
            self::GEMINI => [
                'contents' => [['parts' => [['text' => $prompt]]]],
                'generationConfig' => ['temperature' => 0.2],
            ],
            default => [],
        };
    }

    /**
     * The model's text, dug out of whichever envelope it arrived in.
     *
     * An error in the envelope is reported as itself rather than as "no
     * content": a bad key, a model name that does not exist and a rate limit
     * all come back as a perfectly well-formed reply with no text in it, and
     * those are the three things most likely to happen to somebody setting
     * this up.
     *
     * @throws WorkspaceError
     */
    public function text(string $raw): string
    {
        $object = json_decode($raw, true);
        if (!is_array($object)) {
            throw WorkspaceError::critique(
                "The provider's reply was not JSON.",
                'Check the web server error log for what it actually sent.'
            );
        }

        if (isset($object['error']) && is_array($object['error'])) {
            $message = $object['error']['message'] ?? null;
            throw WorkspaceError::critique(
                is_string($message) ? $message : 'The provider rejected the request.',
                'Check the API key and the model name in the server configuration.'
            );
        }

        $text = match ($this->id) {
            self::OPENAI => $object['choices'][0]['message']['content'] ?? null,
            self::ANTHROPIC => self::joinText($object['content'] ?? null),
            self::GEMINI => self::joinText($object['candidates'][0]['content']['parts'] ?? null),
            default => null,
        };

        if (!is_string($text) || $text === '') {
            throw WorkspaceError::critique(
                "The provider's reply contained no text.",
                'Check the web server error log for what it actually sent.'
            );
        }
        return $text;
    }

    private static function joinText(mixed $blocks): ?string
    {
        if (!is_array($blocks)) {
            return null;
        }
        $parts = [];
        foreach ($blocks as $block) {
            if (is_array($block) && isset($block['text']) && is_string($block['text'])) {
                $parts[] = $block['text'];
            }
        }
        return $parts === [] ? null : implode('', $parts);
    }
}
