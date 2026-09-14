<?php

declare(strict_types=1);

namespace MarkdownEditor;

/**
 * Port of Shared/Sources/MarkdownEditorCore/KonvoSkill.swift.
 *
 * Which copy of the KONVO skill the critique is running against.
 *
 * The critique's whole shape -- the severities, the categories, the "quote it
 * character for character" rule that every highlight depends on -- comes from
 * the skill rather than from this app. So when a critique starts returning
 * something the rail cannot draw, the first useful question is which version
 * of the skill answered.
 *
 * The macOS app reads a git checkout in the reader's home directory and can
 * pull it. A web server has neither, so the pass is vendored into the
 * repository by `tools/vendor-konvo-skill.sh` and deployed with the app. The
 * version is read from the file that script writes beside it, which means the
 * app reports the copy it is actually sending rather than the newest one that
 * exists.
 */
final class KonvoSkill
{
    /** The heading that opens the part of the skill this app uses. */
    public const CRITIQUE_HEADING = '## Critique';

    /**
     * The skill's critique pass, pulled out of `SKILL.md`.
     *
     * The app sends this with every request, so the critique is the skill's
     * rather than the model's own idea of what a critique is. Sending the
     * whole file would be wasteful and mostly irrelevant -- it is 110KB, and
     * all but this section is about *writing* rather than about reading
     * somebody else's draft.
     *
     * Taken as "from `## Critique` up to the next heading at the same level",
     * which is how the file is organised. A `##` inside a fenced code block
     * would end the section early; the skill has none in this section today,
     * and the check that measures the extracted length would catch it if one
     * arrived.
     */
    public static function critiquePass(string $markdown): ?string
    {
        $start = strpos($markdown, self::CRITIQUE_HEADING);
        if ($start === false) {
            return null;
        }
        $rest = substr($markdown, $start);
        $next = strpos($rest, "\n## ", strlen(self::CRITIQUE_HEADING));
        $section = trim($next === false ? $rest : substr($rest, 0, $next));
        return $section === '' ? null : $section;
    }

    /** Where the vendored copy lives, relative to the private half of the app. */
    public static function directory(): string
    {
        return dirname(__DIR__) . '/skill';
    }

    /**
     * The pass to send, or null when nothing was vendored.
     *
     * Null is a real state rather than an error: the app still critiques, and
     * says on screen that it is doing so without the skill. Failing the whole
     * request because a file is missing would turn a degraded critique into no
     * critique at all.
     */
    public static function pass(): ?string
    {
        $path = self::directory() . '/critique-pass.md';
        if (!is_file($path) || !is_readable($path)) {
            return null;
        }
        $contents = file_get_contents($path);
        if ($contents === false) {
            return null;
        }
        $trimmed = trim($contents);
        return $trimmed === '' ? null : $trimmed;
    }

    /**
     * What was vendored, as the three lines the vendoring script writes:
     * commit, ISO date, subject.
     *
     * Parsed rather than read as one blob because a commit subject can contain
     * anything, including something that looks like another field.
     *
     * @return array{commit: string, date: ?string, subject: string}|null
     */
    public static function version(): ?array
    {
        $path = self::directory() . '/version.txt';
        if (!is_file($path) || !is_readable($path)) {
            return null;
        }
        $contents = file_get_contents($path);
        if ($contents === false) {
            return null;
        }
        return self::parseVersion($contents);
    }

    /**
     * @return array{commit: string, date: ?string, subject: string}|null
     */
    public static function parseVersion(string $contents): ?array
    {
        $lines = explode("\n", str_replace("\r\n", "\n", $contents));
        if (count($lines) < 2) {
            return null;
        }
        $commit = trim($lines[0]);
        if ($commit === '') {
            return null;
        }
        $date = trim($lines[1]);
        // Everything after the date is the subject, rejoined: a commit subject
        // is one line, but taking only the third would silently truncate one
        // that somehow is not.
        $subject = trim(implode(' ', array_slice($lines, 2)));
        return [
            'commit' => $commit,
            'date' => $date === '' ? null : $date,
            'subject' => $subject,
        ];
    }

    /** How to describe the vendored copy in a sentence. */
    public static function summary(array $version): string
    {
        $parts = [$version['commit']];
        if (is_string($version['date'] ?? null) && $version['date'] !== '') {
            $timestamp = strtotime($version['date']);
            if ($timestamp !== false) {
                $parts[] = date('M j, Y', $timestamp);
            }
        }
        return implode(' · ', $parts);
    }
}
