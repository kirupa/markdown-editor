// Tests for the critique's ported logic.
//
// Mirrors the Swift suites in Shared/Tests/MarkdownEditorCoreTests, because
// parity here is not assumed but demonstrated (PRD WX-5): the anchoring and
// the decoder are what every highlight in the document depends on, and both
// fail quietly when they fail.

import { suite, test, expect, expectEqual } from './harness.js';
import {
  decodeCritiqueReport,
  extractJSONObject,
  findingAdvice,
  findingAdviceLabel,
  parseSeverity,
} from '../app/core/critique-report.js';
import {
  anchorFindings,
  fold,
  occurrences,
  paragraphNumber,
  paragraphRanges,
  rangeForFinding,
} from '../app/core/critique-anchoring.js';
import { critiqueScore, critiqueVerdict, scoreForPenalty } from '../app/core/critique-score.js';
import {
  highlightsFor,
  makeItems,
  reorder,
  resolutionKey,
  scoreFor,
  severityCounts,
} from '../app/core/critique-model.js';
import { adjustAnchor, editBetween } from '../app/core/critique-anchor-tracking.js';
import { makeRange } from '../app/core/range.js';

function finding(overrides = {}) {
  return {
    id: overrides.id ?? 'f1',
    severity: 'medium',
    category: 'Clarity and precision',
    needsVerification: false,
    location: '',
    quote: '',
    why: 'because',
    fix: null,
    direction: null,
    ...overrides,
  };
}

suite('Reading a critique out of a reply', () => {
  test('a bare JSON object decodes', () => {
    const report = decodeCritiqueReport(
      '{"jobRead":"a tutorial","overall":"fine","findings":[]}'
    );
    expectEqual(report.jobRead, 'a tutorial');
    expectEqual(report.overall, 'fine');
    expectEqual(report.findings.length, 0);
  });

  test('prose and a code fence around the object are ignored', () => {
    const report = decodeCritiqueReport(
      'Here you go:\n```json\n{"jobRead":"x","findings":[]}\n```\nHope that helps.'
    );
    expectEqual(report.jobRead, 'x');
  });

  test('a brace inside a quoted passage does not end the object early', () => {
    // The failure this guards is not hypothetical: a draft about code quotes
    // braces, and counting them without minding string literals loses every
    // finding after the first one.
    const reply = '{"findings":[{"quote":"if (x) { y }","why":"unclear","severity":"high"},'
      + '{"quote":"second","why":"also unclear","severity":"low"}]}';
    const report = decodeCritiqueReport(reply);
    expectEqual(report.findings.length, 2);
    expectEqual(report.findings[0].quote, 'if (x) { y }');
  });

  test('an escaped quote inside a string does not end it', () => {
    const json = extractJSONObject('{"why":"they said \\"no\\" twice"}');
    expectEqual(json, '{"why":"they said \\"no\\" twice"}');
  });

  test('a reply with no object at all is a failure, not an empty report', () => {
    let threw = false;
    try {
      decodeCritiqueReport('I would rather not.');
    } catch (error) {
      threw = true;
      expectEqual(error.kind, 'noJSONFound');
    }
    expect(threw, 'expected a decode failure');
  });

  test('a finding with neither a passage nor a reason is dropped', () => {
    const report = decodeCritiqueReport(
      '{"findings":[{"severity":"high"},{"quote":"real","why":"yes"}]}'
    );
    expectEqual(report.findings.length, 1);
    expectEqual(report.findings[0].quote, 'real');
  });

  test('severity is read forgivingly', () => {
    expectEqual(parseSeverity('High'), 'high');
    expectEqual(parseSeverity('critical'), 'high');
    expectEqual(parseSeverity('  Nit '), 'low');
    expectEqual(parseSeverity('anything else'), 'medium');
    expectEqual(parseSeverity(null), 'medium');
  });

  test('needsVerification accepts the several ways a model writes a boolean', () => {
    const report = decodeCritiqueReport(
      '{"findings":[{"quote":"a","why":"b","needsVerification":"yes"},'
      + '{"quote":"c","why":"d","needsVerification":1},'
      + '{"quote":"e","why":"f","needsVerification":false}]}'
    );
    expectEqual(report.findings.map((entry) => entry.needsVerification), [true, true, false]);
  });

  test('keep is read as whatWorks when the newer field is absent', () => {
    // Saved critiques written by an earlier build still carry the old name,
    // and falling back keeps them readable rather than blank.
    const report = decodeCritiqueReport('{"keep":["the opening"],"findings":[]}');
    expectEqual(report.whatWorks, ['the opening']);
  });

  test('the advice is the fix when there is one and the direction otherwise', () => {
    expectEqual(findingAdvice(finding({ fix: 'say "cannot"' })), 'say "cannot"');
    expectEqual(findingAdviceLabel(finding({ fix: 'say "cannot"' })), 'Fix');
    expectEqual(findingAdvice(finding({ fix: '  ', direction: 'cut it back' })), 'cut it back');
    expectEqual(findingAdviceLabel(finding({ fix: '  ', direction: 'cut it back' })), 'Direction');
    expectEqual(findingAdvice(finding()), null);
  });
});

suite('Anchoring a critique to the draft', () => {
  const draft = 'The cat sat on the mat.\n\nThe dog sat on the log.\n\nThe cat sat again.';

  test('an exact quote is found', () => {
    const range = rangeForFinding(finding({ quote: 'The dog sat' }), draft);
    expectEqual(range, makeRange(25, 11));
  });

  test('a quote the model retyped is still found', () => {
    // Curly quotes, an em dash and a collapsed line break are all things a
    // model does to a passage it is copying. The passage is still there; the
    // bytes are not.
    const text = 'She said “no” — twice,\nand meant it.';
    const range = rangeForFinding(finding({ quote: 'She said "no" - twice, and meant it.' }), text);
    expect(range !== null, 'a retyped quote should still anchor');
    expectEqual(range.location, 0);
  });

  test('a quote that is simply not there does not anchor', () => {
    expectEqual(rangeForFinding(finding({ quote: 'the hamster' }), draft), null);
  });

  test('an empty quote does not anchor', () => {
    expectEqual(rangeForFinding(finding({ quote: '   ' }), draft), null);
  });

  test('the location picks between repeated passages', () => {
    const text = 'alpha\n\nbeta\n\nalpha';
    const first = rangeForFinding(finding({ quote: 'alpha', location: 'paragraph 1' }), text);
    const third = rangeForFinding(finding({ quote: 'alpha', location: 'paragraph 3' }), text);
    expectEqual(first, makeRange(0, 5));
    expectEqual(third, makeRange(13, 5));
  });

  test('two findings quoting the same words take different occurrences', () => {
    // Otherwise the rail stacks two cards on one highlight while an identical
    // passage sits unmarked.
    const text = 'alpha\n\nalpha';
    const anchors = anchorFindings(
      [finding({ id: 'a', quote: 'alpha' }), finding({ id: 'b', quote: 'alpha' })],
      text
    );
    expectEqual(anchors[0].range, makeRange(0, 5));
    expectEqual(anchors[1].range, makeRange(7, 5));
  });

  test('paragraphs are blank-line separated blocks, not lines', () => {
    // A paragraph that wraps is still one paragraph, so the numbers in a
    // critique line up with the way a reader counts them.
    const text = 'one\nstill one\n\ntwo\n\n\nthree';
    expectEqual(paragraphRanges(text).length, 3);
  });

  test('a paragraph number is read out of the location string', () => {
    expectEqual(paragraphNumber('Opening, paragraph 2'), 2);
    expectEqual(paragraphNumber('paragraph 11'), 11);
    expectEqual(paragraphNumber('the ending'), null);
  });

  test('folding keeps an offset for every character it produces', () => {
    const folded = fold('a  b');
    expectEqual(folded.value, 'a b');
    expectEqual(folded.offsets.length, folded.value.length);
    // The space kept is the first of the run, so a match translates back onto
    // real characters rather than onto an approximation of them.
    expectEqual(folded.offsets, [0, 1, 3]);
  });

  test('an exact match wins outright over a relaxed one', () => {
    const text = 'The  cat. The cat.';
    // "The cat" is exactly present at 10, and loosely present at 0. The exact
    // pass runs first and wins, because a verbatim match is the strongest
    // evidence available.
    expectEqual(occurrences('The cat', text), [makeRange(10, 7)]);
  });
});

suite('Scoring a draft', () => {
  test('nothing outstanding is a hundred', () => {
    expectEqual(critiqueScore([]), 100);
  });

  test('the score decays rather than subtracting', () => {
    // A long, thorough critique of a decent draft must not reach zero, or the
    // number stops moving however much the author fixes.
    const twelve = Array.from({ length: 12 }, () => finding({ severity: 'high' }));
    const score = critiqueScore(twelve);
    expect(score > 0, 'the score should never reach zero');
    expect(score < 15, `twelve high findings should be dire, got ${score}`);
  });

  test('one high finding lands in the low eighties', () => {
    expectEqual(critiqueScore([finding({ severity: 'high' })]), 82);
  });

  test('the floor is one, not zero', () => {
    expectEqual(scoreForPenalty(100000), 1);
  });

  test('each verdict has a band', () => {
    expectEqual(critiqueVerdict(100), 'Ready');
    expectEqual(critiqueVerdict(90), 'Nearly there');
    expectEqual(critiqueVerdict(70), 'Solid, with work to do');
    expectEqual(critiqueVerdict(40), 'Needs a pass');
    expectEqual(critiqueVerdict(10), 'Needs a rewrite');
  });
});

suite('The rail as data', () => {
  const text = 'alpha beta\n\ngamma delta';

  test('items carry where each finding points', () => {
    const items = makeItems(
      [finding({ id: 'a', quote: 'gamma' }), finding({ id: 'b', quote: 'nowhere' })],
      text
    );
    expectEqual(items[0].range, makeRange(12, 5));
    expectEqual(items[1].range, null);
  });

  test('the rail is in reading order, not severity order', () => {
    // The rail sits beside the text, so reading down the comments should mean
    // reading down the draft.
    const items = reorder(
      makeItems(
        [
          finding({ id: 'late', quote: 'gamma', severity: 'low' }),
          finding({ id: 'early', quote: 'alpha', severity: 'high' }),
        ],
        text
      )
    );
    expectEqual(items.map((item) => item.id), ['early', 'late']);
  });

  test('a finding that could not be anchored goes last, not first', () => {
    const items = reorder(
      makeItems(
        [finding({ id: 'lost', quote: 'nowhere' }), finding({ id: 'found', quote: 'gamma' })],
        text
      )
    );
    expectEqual(items.map((item) => item.id), ['found', 'lost']);
  });

  test('answered notes sink below outstanding ones and stop scoring', () => {
    const items = reorder(
      makeItems([finding({ id: 'a', quote: 'alpha', severity: 'high' })], text, {
        [resolutionKey(finding({ id: 'a', quote: 'alpha', severity: 'high' }))]: 'completed',
      })
    );
    expectEqual(scoreFor(items), 100);
    expectEqual(highlightsFor(items).length, 0);
  });

  test('a resolution is remembered by what the finding says, not its identity', () => {
    // A re-run produces new identities for the same observations. Without
    // this, every re-run resurrects every dismissal.
    const first = finding({ id: 'run-1', quote: 'alpha', severity: 'high' });
    const second = finding({ id: 'run-2', quote: 'alpha', severity: 'high' });
    expectEqual(resolutionKey(first), resolutionKey(second));
  });

  test('highlights are drawn worst last so a high wins an overlap', () => {
    const items = makeItems(
      [
        finding({ id: 'high', quote: 'alpha', severity: 'high' }),
        finding({ id: 'low', quote: 'gamma', severity: 'low' }),
      ],
      text
    );
    expectEqual(highlightsFor(items).map((entry) => entry.id), ['low', 'high']);
  });

  test('severity counts skip the empty ones and lead with the worst', () => {
    const items = makeItems(
      [
        finding({ id: 'a', quote: 'alpha', severity: 'low' }),
        finding({ id: 'b', quote: 'gamma', severity: 'high' }),
      ],
      text
    );
    expectEqual(severityCounts(items), [
      { severity: 'high', count: 1 },
      { severity: 'low', count: 1 },
    ]);
  });
});

suite('Keeping the marks on the words', () => {
  test('an edit after the passage leaves it alone', () => {
    // The boundary that matters most: typing a new sentence onto the end of a
    // marked one must not drag the mark over the new sentence.
    const range = makeRange(0, 10);
    const edit = { location: 10, removed: 0, inserted: 5, insertedBreaksLine: false };
    expectEqual(adjustAnchor(range, edit), makeRange(0, 10));
  });

  test('an edit before the passage slides it', () => {
    const edit = { location: 0, removed: 0, inserted: 4, insertedBreaksLine: false };
    expectEqual(adjustAnchor(makeRange(10, 5), edit), makeRange(14, 5));
  });

  test('an insertion strictly inside grows the passage', () => {
    const edit = { location: 5, removed: 0, inserted: 3, insertedBreaksLine: false };
    expectEqual(adjustAnchor(makeRange(0, 10), edit), makeRange(0, 13));
  });

  test('a line break inside the passage ends it there', () => {
    // What follows is a new paragraph, and a critique of one paragraph should
    // not reach into the next.
    const edit = { location: 5, removed: 1, inserted: 1, insertedBreaksLine: true };
    expectEqual(adjustAnchor(makeRange(0, 10), edit), makeRange(0, 5));
  });

  test('deleting the whole passage removes the mark', () => {
    const edit = { location: 0, removed: 10, inserted: 0, insertedBreaksLine: false };
    expectEqual(adjustAnchor(makeRange(0, 10), edit), null);
  });

  test('one keystroke is derived as one replacement', () => {
    const edit = editBetween('hello world', 'hello brave world');
    expectEqual(edit.location, 6);
    expectEqual(edit.removed, 0);
    expectEqual(edit.inserted, 6);
  });

  test('no change is no edit', () => {
    expectEqual(editBetween('same', 'same'), null);
  });

  test('a typed return is seen as breaking the line', () => {
    // It arrives as a one-character replacement rather than a pure insertion,
    // which is why this is checked before the insert/replace split.
    const edit = editBetween('one two', 'one\ntwo');
    expect(edit.insertedBreaksLine, 'a newline should be recognised');
  });
});
