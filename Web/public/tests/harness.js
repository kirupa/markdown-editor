// Minimal test harness, shaped after the Swift Testing API the macOS core uses
// (`@Suite`, `@Test`, `#expect`) so ported tests read like their originals.
//
// It has no dependencies and no build step: the same modules run in a browser
// via /tests/ and headlessly via `node Tests/run.mjs`.

const suites = [];
let current = null;

export function suite(name, body) {
  const entry = { name, tests: [] };
  suites.push(entry);
  const previous = current;
  current = entry;
  try {
    body();
  } finally {
    current = previous;
  }
}

export function test(name, body) {
  if (!current) throw new Error(`test "${name}" declared outside a suite`);
  current.tests.push({ name, body });
}

class ExpectationFailure extends Error {}

/** Asserts a condition, mirroring `#expect(...)`. */
export function expect(condition, message = 'expectation failed') {
  if (!condition) throw new ExpectationFailure(message);
}

/** Asserts deep equality, reporting both sides on failure. */
export function expectEqual(actual, expected, message = '') {
  if (!deepEqual(actual, expected)) {
    const prefix = message ? `${message}: ` : '';
    throw new ExpectationFailure(
      `${prefix}expected ${display(expected)} but got ${display(actual)}`
    );
  }
}

export function expectThrows(body, message = 'expected an error to be thrown') {
  try {
    body();
  } catch {
    return;
  }
  throw new ExpectationFailure(message);
}

/**
 * The asynchronous counterpart of `expectThrows`.
 *
 * Separate rather than folded into `expectThrows`, because a rejected promise
 * escaping a `try` block is precisely the mistake this is here to catch.
 */
export async function expectRejects(body, message = 'expected a rejection') {
  try {
    await body();
  } catch {
    return;
  }
  throw new ExpectationFailure(message);
}

function deepEqual(a, b) {
  if (a === b) return true;
  if (typeof a !== typeof b) return false;
  if (a === null || b === null) return false;
  if (typeof a !== 'object') return Number.isNaN(a) && Number.isNaN(b);
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a)) {
    return a.length === b.length && a.every((item, index) => deepEqual(item, b[index]));
  }
  const keys = Object.keys(a);
  if (keys.length !== Object.keys(b).length) return false;
  return keys.every(
    (key) => Object.prototype.hasOwnProperty.call(b, key) && deepEqual(a[key], b[key])
  );
}

function display(value) {
  if (typeof value === 'string') return JSON.stringify(value);
  if (value && typeof value === 'object') {
    try {
      return JSON.stringify(value);
    } catch {
      return String(value);
    }
  }
  return String(value);
}

/**
 * Runs every registered suite.
 *
 * Async, and awaits whatever a test returns. It has to: a test body that
 * returns a rejected promise would otherwise be recorded as a pass, and the
 * cloud backend is asynchronous throughout.
 *
 * @param {(event: object) => void} [report] receives `suite`, `pass`, `fail`,
 *   and `done` events so callers can render however they like.
 */
export async function runAll(report = () => {}) {
  let passed = 0;
  const failures = [];

  for (const entry of suites) {
    report({ kind: 'suite', name: entry.name, count: entry.tests.length });
    for (const unit of entry.tests) {
      try {
        await unit.body();
        passed += 1;
        report({ kind: 'pass', suite: entry.name, name: unit.name });
      } catch (error) {
        const failure = {
          suite: entry.name,
          name: unit.name,
          message: error instanceof Error ? error.message : String(error),
          stack: error instanceof Error ? error.stack : undefined,
        };
        failures.push(failure);
        report({ kind: 'fail', ...failure });
      }
    }
  }

  const summary = {
    kind: 'done',
    passed,
    failed: failures.length,
    total: passed + failures.length,
    suites: suites.length,
    failures,
  };
  report(summary);
  return summary;
}

export function registeredSuites() {
  return suites;
}
