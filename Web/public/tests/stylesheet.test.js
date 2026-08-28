// The stylesheet against the markup, and against the theme it is written for.
//
// Two bugs shipped that neither the unit tests nor the browser checks could
// see, because both were a stylesheet quietly disagreeing with something else:
//
//   * `.me-image-size` set `display: flex` with no `[hidden]` override. The
//     `hidden` attribute is only a UA-stylesheet `display: none`, which any
//     author rule beats — so the empty size panel sat over every document,
//     permanently.
//
//   * `#alertLayer` shipped without the `hidden` attribute. It is a fixed,
//     inset-0 element carrying the dimming behind a dialog, and the code that
//     shows dialogs only ever *unsets* `hidden`. So the whole app was dimmed
//     28% from load until some dialog happened to open and close. A page whose
//     theme says `#ffffff` was measured on screen as `rgb(184, 184, 184)`,
//     which is exactly 255 x 0.72.
//
// Both are invisible to a DOM test written against the same wrong assumption,
// and neither changes any behaviour that has a return value. What they do have
// in common is that they are decidable by reading the files, which is what this
// does. Reading files means node, so this suite checks the repository rather
// than the running app.

import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { suite, test, expect } from './harness.js';

const read = (relative) =>
  readFileSync(fileURLToPath(new URL(relative, import.meta.url)), 'utf8');

const appCss = read('../css/app.css');
const themesCss = read('../css/themes.css');
const markup = read('../index.php');

// ── a deliberately small CSS reader ──────────────────────────────────────────
//
// Only rules whose selector list contains a bare `.class` or `.class[hidden]`
// are collected. Anything more specific is someone qualifying a rule on
// purpose, and guessing at which of those "counts" would make the failures
// arbitrary. Being narrow keeps every failure this produces a real one.

function readRules(css) {
  const withoutComments = css.replace(/\/\*[\s\S]*?\*\//g, '');
  const rules = [];
  for (const match of withoutComments.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const selectors = match[1].split(',').map((s) => s.trim()).filter(Boolean);
    const declarations = new Map();
    for (const part of match[2].split(';')) {
      const colon = part.indexOf(':');
      if (colon < 0) continue;
      declarations.set(part.slice(0, colon).trim(), part.slice(colon + 1).trim());
    }
    rules.push({ selectors, declarations });
  }
  return rules;
}

const rules = readRules(appCss);

/** Declarations that apply to a bare `.class` selector, merged in source order. */
const byClass = new Map();
/** Classes that have an explicit `.class[hidden] { display: none }`. */
const hiddenOverride = new Set();

for (const rule of rules) {
  for (const selector of rule.selectors) {
    const bare = /^\.([A-Za-z0-9_-]+)$/.exec(selector);
    if (bare) {
      const existing = byClass.get(bare[1]) ?? new Map();
      for (const [property, value] of rule.declarations) existing.set(property, value);
      byClass.set(bare[1], existing);
      continue;
    }
    const guarded = /^\.([A-Za-z0-9_-]+)\[hidden\]$/.exec(selector);
    if (guarded && rule.declarations.get('display') === 'none') {
      hiddenOverride.add(guarded[1]);
    }
  }
}

/** Every element in the markup that carries an id, with its classes. */
function markupElements() {
  const found = [];
  for (const tag of markup.matchAll(/<([a-z]+)\b([^>]*)>/g)) {
    const attributes = tag[2];
    const id = /\bid="([^"]+)"/.exec(attributes)?.[1];
    if (!id) continue;
    const classes = (/\bclass="([^"]*)"/.exec(attributes)?.[1] ?? '')
      .trim().split(/\s+/).filter(Boolean);
    found.push({ id, classes, hasHiddenAttribute: /\shidden(\s|=|\/|>|$)/.test(attributes) });
  }
  return found;
}

const elements = markupElements();

/**
 * Classes whose elements the application hides by the `hidden` attribute.
 *
 * Two idioms, both matched textually rather than by parsing. Elements written
 * into `index.php` are found by id; elements built in JS are found by pairing a
 * `x.className = '…'` with an `x.hidden = …` on the *same receiver text* in the
 * same file, which is how every builder in this codebase is written:
 *
 *     panel.className = 'me-image-size';
 *     panel.hidden = true;
 *
 * A builder that spells it some other way simply isn't covered, which is the
 * same position this test is in today for code it cannot see.
 */
function classesHiddenByCode() {
  const directory = fileURLToPath(new URL('../app/', import.meta.url));
  const sources = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.isDirectory()) walk(`${dir}${entry.name}/`);
      else if (entry.name.endsWith('.js')) sources.push(readFileSync(dir + entry.name, 'utf8'));
    }
  };
  walk(directory);

  const receiver = String.raw`[A-Za-z_$][\w$.]*`;
  const ids = new Set();
  const classes = new Set();
  for (const source of sources) {
    for (const m of source.matchAll(/(?:element|getElementById)\(\s*'([^']+)'\s*\)\.hidden\s*=/g)) {
      ids.add(m[1]);
    }
    const hides = new Set(
      [...source.matchAll(new RegExp(String.raw`(${receiver})\.hidden\s*=`, 'g'))].map((m) => m[1])
    );
    const named = [
      ...source.matchAll(new RegExp(String.raw`(${receiver})\.className\s*=\s*'([^']+)'`, 'g')),
      ...source.matchAll(new RegExp(String.raw`(${receiver})\.classList\.add\(\s*'([^']+)'`, 'g')),
    ];
    for (const [, target, value] of named) {
      if (hides.has(target)) for (const name of value.trim().split(/\s+/)) classes.add(name);
    }
  }
  return { ids, classes };
}

const hiddenByCode = classesHiddenByCode();

suite('stylesheet conformance', () => {
  test('every --me- variable used without a fallback is defined somewhere', () => {
    const fromJs = new Set();
    const directory = fileURLToPath(new URL('../app/', import.meta.url));
    const walk = (dir) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        if (entry.isDirectory()) walk(`${dir}${entry.name}/`);
        else if (entry.name.endsWith('.js')) {
          for (const m of readFileSync(dir + entry.name, 'utf8')
            .matchAll(/setProperty\(\s*'(--me-[a-z0-9-]+)'/g)) fromJs.add(m[1]);
        }
      }
    };
    walk(directory);

    const defined = new Set([
      ...[...themesCss.matchAll(/(--me-[a-z0-9-]+)\s*:/g)].map((m) => m[1]),
      ...[...appCss.matchAll(/(--me-[a-z0-9-]+)\s*:/g)].map((m) => m[1]),
      ...fromJs,
    ]);
    // Only uses with no fallback can fail. `var(--x, 0px)` is always valid, so
    // flagging it would be noise rather than a finding.
    const used = new Set(
      [...appCss.matchAll(/var\(\s*(--me-[a-z0-9-]+)\s*\)/g)].map((m) => m[1])
    );
    const missing = [...used].filter((name) => !defined.has(name)).sort();
    // An undefined custom property makes the whole declaration invalid at
    // computed-value time, so the property silently falls back to `unset`.
    // `background: var(--me-nope)` is transparent, not an error.
    expect(
      missing.length === 0,
      `app.css uses variables nothing defines: ${missing.join(', ')}`
    );
  });

  test('anything the code hides has a [hidden] rule that can win', () => {
    // `hidden` is only a UA-stylesheet `display: none`, and any author rule
    // that sets `display` beats it. So an element the code hides whose class
    // sets a display needs the override spelled out, or it never disappears.
    const suspects = new Set(hiddenByCode.classes);
    for (const element of elements) {
      if (!hiddenByCode.ids.has(element.id) && !element.hasHiddenAttribute) continue;
      for (const className of element.classes) suspects.add(className);
    }

    const broken = [];
    for (const className of suspects) {
      const display = byClass.get(className)?.get('display');
      if (!display || display === 'none') continue;
      if (hiddenOverride.has(className)) continue;
      broken.push(`.${className} is hidden by the hidden attribute, but sets ` +
        `display: ${display} and has no .${className}[hidden] override`);
    }
    expect(broken.length === 0, broken.join('\n      '));
  });

  test('every full-window layer that paints starts hidden in the markup', () => {
    const painting = [];
    for (const [className, declarations] of byClass) {
      const position = declarations.get('position');
      const inset = declarations.get('inset');
      const background = declarations.get('background') ?? '';
      const paints = background !== '' && background !== 'none' &&
        !background.includes('transparent');
      if ((position === 'fixed' || position === 'absolute') && inset === '0' && paints) {
        painting.push(className);
      }
    }
    // The pattern is worth keeping honest even if the count changes: this is
    // the shape of element that dims everything behind it.
    expect(painting.length > 0, 'expected to find at least one full-window layer');

    const broken = [];
    for (const className of painting) {
      for (const element of elements) {
        if (!element.classes.includes(className)) continue;
        if (!element.hasHiddenAttribute) {
          broken.push(`#${element.id} (.${className}) covers the window and paints, ` +
            `but does not carry the hidden attribute`);
        }
      }
    }
    expect(broken.length === 0, broken.join('\n      '));
  });

  test('the explorer floats on desktop so the document cannot be displaced', () => {
    // WT-13. If the explorer takes part in the row again, opening it shifts the
    // document sideways and re-centres the text in whatever is left over.
    const floats = rules.some(
      (rule) =>
        rule.selectors.some((s) => s.includes('.me-sidebar') && s.includes(':not([data-layout="mobile"])')) &&
        rule.declarations.get('position') === 'absolute'
    );
    expect(floats, 'the desktop explorer must be positioned out of the flow');
  });
});
