<?php

declare(strict_types=1);

namespace MarkdownEditor;

/**
 * Running a critique, server-side.
 *
 * The key is the **reader's**, sent with the request, spent here and forgotten.
 *
 * That arrangement is the answer to two problems at once. A page open to
 * anyone cannot run critiques on the site owner's account, because the first
 * person to notice would be spending somebody else's money; and a browser
 * cannot call these providers itself, because two of the three answer a
 * cross-origin request by refusing it. So the browser holds the key and this
 * makes the call.
 *
 * Nothing about the key is kept. It is not written to disk, not put in a
 * session, and not logged -- the catch-all handler in Api.php logs a message
 * and never the request.
 *
 * A server may still hold a key of its own, for a private install where that
 * is the point, but only when `MDE_CRITIQUE_ALLOW_SERVER_KEY` says so. The
 * default is off, because the failure mode of the other default is a bill.
 */
final class Critique
{
    /** How long to wait for a provider before giving up, in seconds. */
    private const TIMEOUT = 120;

    /**
     * Longest draft that will be sent.
     *
     * Not a limit on the editor -- documents can be any size -- but on what is
     * worth posting to a model in one request. A draft past this is beyond
     * what a critique can hold in view anyway, and the failure to avoid is a
     * 90-second wait ending in a provider-side length error the reader cannot
     * act on.
     */
    private const MAX_DOCUMENT = 200000;

    public function __construct(
        private readonly string $provider,
        private readonly string $model,
        private readonly string $apiKey
    ) {
    }

    /**
     * The service for one request, using the key the browser sent.
     *
     * The provider and the model are validated rather than trusted: the
     * provider must be one this build knows, and the model must be one that
     * provider offers. Otherwise the model name is a string from a page that
     * ends up inside a URL, which is a request forgery waiting for somebody to
     * find it.
     *
     * @throws WorkspaceError
     */
    public static function fromRequest(array $body): self
    {
        $key = self::text($body['key'] ?? null);
        if ($key === null) {
            return self::fromServerKey();
        }

        $providerID = self::text($body['provider'] ?? null) ?? CritiqueProvider::OPENAI;
        if (!CritiqueProvider::isKnown($providerID)) {
            throw WorkspaceError::critique(
                'That is not a provider this editor knows.',
                'Choose OpenAI, Anthropic or Google Gemini in the critique settings.'
            );
        }
        $provider = new CritiqueProvider($providerID);

        $model = self::text($body['model'] ?? null) ?? $provider->defaultModel();
        if (!in_array($model, $provider->models(), true)) {
            throw WorkspaceError::critique(
                sprintf('%s does not offer a model called "%s".', $provider->title(), $model),
                'Pick one from the list in the critique settings.'
            );
        }

        return new self($providerID, $model, $key);
    }

    /**
     * The server's own key, for an install where that is deliberate.
     *
     * Off unless `MDE_CRITIQUE_ALLOW_SERVER_KEY` is set, because a public page
     * quietly spending the owner's account is a failure nobody notices until
     * the bill, and a host that already has `OPENAI_API_KEY` set for something
     * else would otherwise opt in by accident.
     *
     * @throws WorkspaceError
     */
    private static function fromServerKey(): self
    {
        $critique = self::serverKey();
        if ($critique === null) {
            throw WorkspaceError::critique(
                'A critique needs an API key.',
                'Add one in the critique settings. It stays in this browser.'
            );
        }
        return $critique;
    }

    public static function serverKey(): ?self
    {
        if (self::env('MDE_CRITIQUE_ALLOW_SERVER_KEY') === null) {
            return null;
        }
        $providerID = self::env('MDE_CRITIQUE_PROVIDER') ?? CritiqueProvider::OPENAI;
        if (!CritiqueProvider::isKnown($providerID)) {
            return null;
        }
        $provider = new CritiqueProvider($providerID);

        $key = self::env('MDE_CRITIQUE_KEY') ?? self::env($provider->keyVariable());
        if ($key === null) {
            return null;
        }

        $model = self::env('MDE_CRITIQUE_MODEL') ?? $provider->defaultModel();
        return new self($providerID, $model, $key);
    }

    /**
     * What the browser is allowed to know about the server.
     *
     * Which KONVO skill went out with this deploy, and whether the server has
     * a key of its own to fall back on -- so the rail can tell "add a key" from
     * "ready to go" without asking for one that is not needed. Never a key, and
     * never anything about the reader's.
     */
    public static function describe(): array
    {
        $version = KonvoSkill::version();
        $server = self::serverKey();
        return [
            'serverKey' => $server !== null,
            'serverProvider' => $server === null
                ? null
                : (new CritiqueProvider($server->provider))->title(),
            'serverModel' => $server?->model,
            'skill' => $version === null ? null : [
                'commit' => $version['commit'],
                'subject' => $version['subject'],
                'summary' => KonvoSkill::summary($version),
                'loaded' => KonvoSkill::pass() !== null,
            ],
        ];
    }

    /** A non-empty trimmed string, or null. */
    private static function text(mixed $value): ?string
    {
        if (!is_string($value)) {
            return null;
        }
        $trimmed = trim($value);
        return $trimmed === '' ? null : $trimmed;
    }

    private static function env(string $name): ?string
    {
        $value = getenv($name);
        if (!is_string($value) || trim($value) === '') {
            $value = $_SERVER[$name] ?? null;
        }
        return is_string($value) && trim($value) !== '' ? trim($value) : null;
    }

    /**
     * Critiques a draft and returns the model's raw reply.
     *
     * Raw on purpose. The browser decodes it with the same ported decoder the
     * Mac uses, so a reply that is 90% right is shown rather than thrown away
     * by a second, differently-forgiving parser here.
     *
     * @throws WorkspaceError
     */
    public function run(string $document, ?string $focus = null): array
    {
        if (trim($document) === '') {
            throw WorkspaceError::critique(
                'There is nothing to critique.',
                'Write something first, then ask for a critique.'
            );
        }
        if (strlen($document) > self::MAX_DOCUMENT) {
            throw WorkspaceError::critique(
                'This document is too long to critique in one pass.',
                'Critique a section by selecting it, or split the document.'
            );
        }

        $provider = new CritiqueProvider($this->provider);
        $prompt = CritiqueRequest::prompt($document, $focus, KonvoSkill::pass());
        $reply = $this->post(
            $provider->endpoint($this->model),
            $provider->headers($this->apiKey),
            $provider->body($prompt, $this->model)
        );

        return [
            'reply' => $provider->text($reply),
            'provider' => $this->provider,
            'model' => $this->model,
        ];
    }

    /**
     * Asks the provider for one word, to prove the path works.
     *
     * The same path a critique takes, deliberately: a test that reached the
     * provider some other way would prove something other than the thing the
     * reader is about to rely on. A critique takes the better part of a
     * minute, and until it fails there is no way to tell a mistyped key from a
     * model the account cannot reach from a network that is down.
     */
    public function test(): array
    {
        $provider = new CritiqueProvider($this->provider);
        $reply = $this->post(
            $provider->endpoint($this->model),
            $provider->headers($this->apiKey),
            $provider->body('Reply with the single word: OK', $this->model)
        );
        $text = trim($provider->text($reply));
        return [
            'ok' => true,
            'detail' => sprintf('%s · %s answered.', $provider->title(), $this->model),
            'reply' => mb_substr($text, 0, 120),
        ];
    }

    /**
     * @param list<string> $headers
     * @throws WorkspaceError
     */
    private function post(string $url, array $headers, array $body): string
    {
        $payload = json_encode($body, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        if ($payload === false) {
            throw WorkspaceError::critique(
                'The request could not be encoded.',
                'This is a bug; please report it.'
            );
        }

        if (function_exists('curl_init')) {
            return $this->postWithCurl($url, $headers, $payload);
        }
        return $this->postWithStreams($url, $headers, $payload);
    }

    private function postWithCurl(string $url, array $headers, string $payload): string
    {
        $handle = curl_init($url);
        curl_setopt_array($handle, [
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => $payload,
            CURLOPT_HTTPHEADER => $headers,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT => self::TIMEOUT,
            CURLOPT_CONNECTTIMEOUT => 15,
        ]);
        $response = curl_exec($handle);
        $error = curl_error($handle);
        // No curl_close: since PHP 8.0 the handle is an object freed when it
        // goes out of scope, and 8.5 deprecates the call. The deprecation
        // notice is not cosmetic here — on a host with display_errors on it is
        // printed *before* the JSON body, and the browser's JSON.parse then
        // fails on a reply that was otherwise perfectly good.
        if (!is_string($response) || $response === '') {
            // The transport failed, which is a different thing from the model
            // refusing, and the two want different fixes.
            throw WorkspaceError::critique(
                $error !== '' ? 'Could not reach the model: ' . $error : 'The model did not answer.',
                'Check the server can reach the internet, then try again.'
            );
        }
        return $response;
    }

    /**
     * The fallback for a host built without curl.
     *
     * `ignore_errors` matters: without it PHP turns a 401 into a warning and
     * `false`, losing the provider's own explanation of what is wrong with the
     * key -- which is the single most useful sentence in the whole exchange.
     */
    private function postWithStreams(string $url, array $headers, string $payload): string
    {
        $context = stream_context_create([
            'http' => [
                'method' => 'POST',
                'header' => implode("\r\n", $headers),
                'content' => $payload,
                'timeout' => self::TIMEOUT,
                'ignore_errors' => true,
            ],
        ]);
        $response = @file_get_contents($url, false, $context);
        if (!is_string($response) || $response === '') {
            throw WorkspaceError::critique(
                'Could not reach the model.',
                'Check the server can reach the internet, then try again.'
            );
        }
        return $response;
    }
}
