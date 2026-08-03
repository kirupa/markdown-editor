<?php

declare(strict_types=1);

/**
 * A tiny test harness.
 *
 * PHPUnit would mean Composer, and the whole point of this build is that it
 * runs anywhere PHP does. This is shaped after the Swift Testing API the macOS
 * suite uses so the two read the same way.
 */

final class TestRunner
{
    /** @var array<string, list<array{string, callable}>> */
    private array $suites = [];
    private string $current = 'Tests';
    private int $passed = 0;
    /** @var list<string> */
    private array $failures = [];

    public function suite(string $name, callable $body): void
    {
        $previous = $this->current;
        $this->current = $name;
        $this->suites[$name] ??= [];
        $body($this);
        $this->current = $previous;
    }

    public function test(string $name, callable $body): void
    {
        $this->suites[$this->current][] = [$name, $body];
    }

    public function run(): int
    {
        foreach ($this->suites as $suiteName => $tests) {
            foreach ($tests as [$testName, $body]) {
                try {
                    $body($this);
                    $this->passed++;
                } catch (\Throwable $error) {
                    $this->failures[] = sprintf(
                        "%s › %s\n    %s",
                        $suiteName,
                        $testName,
                        $error->getMessage()
                    );
                }
            }
        }

        $total = $this->passed + count($this->failures);
        if ($this->failures === []) {
            printf("✓ %d tests in %d suites passed\n", $total, count($this->suites));
            return 0;
        }

        printf("✗ %d of %d tests failed\n\n", count($this->failures), $total);
        foreach ($this->failures as $failure) {
            echo '  ' . $failure . "\n\n";
        }
        return 1;
    }

    public function expect(bool $condition, string $message = 'Expectation failed'): void
    {
        if (!$condition) {
            throw new \RuntimeException($message);
        }
    }

    public function expectEqual(mixed $actual, mixed $expected, string $message = ''): void
    {
        if ($actual !== $expected) {
            throw new \RuntimeException(sprintf(
                "%sexpected %s but got %s",
                $message === '' ? '' : $message . ': ',
                var_export($expected, true),
                var_export($actual, true)
            ));
        }
    }

    /** Asserts the callable throws a WorkspaceError whose message contains `$needle`. */
    public function expectRejects(callable $body, string $needle = ''): void
    {
        try {
            $body();
        } catch (\MarkdownEditor\WorkspaceError $error) {
            if ($needle !== '' && !str_contains($error->getMessage(), $needle)) {
                throw new \RuntimeException(sprintf(
                    'rejected with "%s" which does not contain "%s"',
                    $error->getMessage(),
                    $needle
                ));
            }
            return;
        }
        throw new \RuntimeException('expected the call to be rejected, but it succeeded');
    }
}
