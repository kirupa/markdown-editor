// Headless test runner.
//
// Optional convenience for development: the same suites run in a browser at
// /tests/, which is the path that needs nothing but PHP installed.
//
//     node Web/tests/run.mjs

import { runAll } from '../public/tests/harness.js';
import { discoverTestModules } from '../public/tests/suites.js';

for (const specifier of discoverTestModules({ includeNode: true })) {
  await import(`../public/tests/${specifier.replace('./', '')}`);
}

const red = (text) => `\u001b[31m${text}\u001b[0m`;
const green = (text) => `\u001b[32m${text}\u001b[0m`;
const dim = (text) => `\u001b[2m${text}\u001b[0m`;

const summary = await runAll((event) => {
  if (event.kind === 'suite') {
    console.log(dim(`\n${event.name} (${event.count})`));
  } else if (event.kind === 'pass') {
    console.log(`  ${green('✔')} ${event.name}`);
  } else if (event.kind === 'fail') {
    console.log(`  ${red('✘')} ${event.name}\n      ${red(event.message)}`);
  }
});

console.log(
  summary.failed === 0
    ? green(`\n${summary.passed} tests in ${summary.suites} suites passed`)
    : red(`\n${summary.failed} of ${summary.total} tests failed`)
);

process.exit(summary.failed === 0 ? 0 : 1);
