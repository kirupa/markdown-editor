// Port of the pure half of macOS/Sources/MarkdownEditor/CritiqueModel.swift.
//
// A critique's state as data: the findings paired with where they point and
// what the author decided about them, in the order the rail shows them.
//
// Kept out of the view for the same reason the Swift keeps it out of the
// SwiftUI: ordering, scoring and staleness are the parts that are easy to get
// quietly wrong, and they are the parts that can be checked without a screen.

import { anchorFindings } from './critique-anchoring.js';
import { countsAgainstScore, critiqueScore, critiqueVerdict } from './critique-score.js';
import { SEVERITY_RANK } from './critique-report.js';

/** What the author decided about a finding. */
export const RESOLUTION = { completed: 'completed', dismissed: 'dismissed' };

export const RESOLUTION_LABEL = { completed: 'Done', dismissed: 'Dismissed' };

/**
 * One row of the rail: a finding, where it points, and what was decided.
 *
 * `range` is null when the quote could not be found. The card is still shown,
 * and says so, rather than highlighting a passage the critique never mentioned.
 */
export function makeItems(findings, text, resolutions = {}) {
  const anchors = anchorFindings(findings, text);
  const byID = new Map(anchors.map((anchor) => [anchor.findingID, anchor.range]));
  return findings.map((finding) => ({
    id: finding.id,
    finding,
    range: byID.get(finding.id) ?? null,
    resolution: resolutions[resolutionKey(finding)] ?? null,
  }));
}

/**
 * How a resolution is remembered across re-runs.
 *
 * By what the finding *says* rather than by its identity, because a re-run
 * produces new identities for the same observations. Without this every re-run
 * resurrects every dismissal, and the feature nags at somebody who told it not
 * to.
 */
export function resolutionKey(finding) {
  return `${finding.severity}\u0000${finding.category}\u0000${finding.quote}\u0000${finding.why}`;
}

export function isOutstanding(item) {
  return item.resolution === null || item.resolution === undefined;
}

export function isAnchored(item) {
  return item.range !== null && item.range !== undefined;
}

/**
 * Outstanding first in reading order, answered ones after them.
 *
 * Ordered by where they are in the document, not by severity. The rail sits
 * beside the text, and a rail beside the text that is ordered by something
 * other than the text reads as a list that happens to be on the right. Reading
 * down the comments should mean reading down the draft. Severity is not lost
 * -- it is the colour and the label on every card, and counted at the top --
 * but it decides how a finding *looks*, not where it sits.
 *
 * A finding whose quote was not found has no position, so it goes last rather
 * than to the top, which is where an unset offset would put it.
 *
 * Answered findings stay in the list rather than disappearing, because a
 * decision the author cannot see is a decision they cannot take back.
 */
export function reorder(items) {
  return items
    .map((element, offset) => ({ element, offset }))
    .sort((left, right) => {
      const leftDone = !isOutstanding(left.element);
      const rightDone = !isOutstanding(right.element);
      if (leftDone !== rightDone) return leftDone ? 1 : -1;
      const leftAt = left.element.range?.location ?? Number.MAX_SAFE_INTEGER;
      const rightAt = right.element.range?.location ?? Number.MAX_SAFE_INTEGER;
      if (leftAt !== rightAt) return leftAt - rightAt;
      // Two findings on the same passage keep the order the critique reported
      // them in, which is worst first.
      return left.offset - right.offset;
    })
    .map((entry) => entry.element);
}

export function outstandingItems(items) {
  return items.filter(isOutstanding);
}

/**
 * How good the draft looks: what is outstanding, what was dismissed, and what
 * the summary still lists. See `critique-score.js` for why Done clears a note
 * and Dismiss does not.
 */
export function scoreFor(items, listedProblems = 0) {
  return critiqueScore(
    items.filter((item) => countsAgainstScore(item.resolution)).map((item) => item.finding),
    listedProblems
  );
}

/**
 * Whether the score is the critic's own rather than the author's: a critique
 * of the text exactly as it stands, with nothing marked Done since. Only then
 * is a hundred "Ready".
 */
export function isConfirmed(items, isStale) {
  return !isStale && !items.some((item) => item.resolution === RESOLUTION.completed);
}

/**
 * Whether an edit from `before` to `after` changes whether the critique of
 * `criticised` still describes the draft.
 *
 * The rail redraws when it does. It used to redraw on an edit only when the
 * edit moved a mark, which an edit after a clean critique never does: the
 * draft could be rewritten under a "Ready" that was no longer the critic's.
 */
export function stalenessChanged(criticised, before, after) {
  if (criticised === null) return false;
  return (criticised !== before) !== (criticised !== after);
}

export function verdictFor(items, { listedProblems = 0, confirmed = true } = {}) {
  return critiqueVerdict(scoreFor(items, listedProblems), confirmed);
}

/**
 * Why the number is what it is, when that is not obvious from the notes, or
 * null when it is.
 *
 * Each line answers a question the old banner left open. "Everything
 * answered" beside a perfect score was the rail agreeing with itself; a score
 * that does not move when a note is dismissed needs to say that it was not
 * meant to. The wording is the Mac's, because it is the same rule.
 */
export function scoreCaption(items, { listedProblems = 0, confirmed = true } = {}) {
  const answered = resolvedCount(items);
  if (scoreFor(items, listedProblems) === 100) {
    if (confirmed) return null;
    return answered > 0
      ? 'Every note answered. Critique again to confirm it is ready.'
      : 'The draft has changed since. Critique again to confirm it is ready.';
  }
  const stillCounting = [];
  if (dismissedCount(items) > 0) stillCounting.push('dismissed notes');
  if (outstandingItems(items).length === 0 && listedProblems > 0) {
    stillCounting.push('the problems in the summary');
  }
  const sentences = [];
  if (answered > 0) sentences.push(`${answered} of ${items.length} answered.`);
  if (stillCounting.length > 0) {
    const list = stillCounting.join(' and ');
    sentences.push(`${list[0].toUpperCase()}${list.slice(1)} still count.`);
  }
  return sentences.length > 0 ? sentences.join(' ') : null;
}

/**
 * The remembered answers that still hold for a fresh critique of the draft.
 *
 * A dismissal carries over: it is the author declining the note, and the
 * critic raising it again is not news. A Done does not, for a finding the
 * critic has just reported again. Done says "fixed", and a critique of the
 * draft as it stands that makes the same objection in the same words says it
 * was not -- so the note comes back open, as it does on the Mac. Carried, it
 * would hold the score at a hundred the critic never gave, and no number of
 * re-runs could confirm it.
 */
export function carriedResolutions(findings, resolutions) {
  const reported = new Set(findings.map(resolutionKey));
  return Object.fromEntries(
    Object.entries(resolutions).filter(
      ([key, resolution]) => !(resolution === RESOLUTION.completed && reported.has(key))
    )
  );
}

/**
 * How many findings there are at each severity, worst first.
 *
 * The rail is in reading order, so this is where the shape of the critique is
 * legible at a glance -- "three high" is the thing an author wants to know
 * before reading anything.
 */
export function severityCounts(items) {
  const outstanding = outstandingItems(items);
  return ['high', 'medium', 'low']
    .map((severity) => ({
      severity,
      count: outstanding.filter((item) => item.finding.severity === severity).length,
    }))
    .filter((entry) => entry.count > 0);
}

/**
 * The highlight ranges, worst last so a high finding is drawn over a low one
 * where two passages overlap.
 *
 * A resolved finding stops shading its passage: the whole point of answering
 * one is that it is no longer something to look at.
 */
export function highlightsFor(items) {
  return items
    .filter((item) => isOutstanding(item) && isAnchored(item))
    .map((item) => ({ id: item.id, range: item.range, severity: item.finding.severity }))
    .sort((left, right) => SEVERITY_RANK[right.severity] - SEVERITY_RANK[left.severity]);
}

export function anchoredCount(items) {
  return items.filter(isAnchored).length;
}

export function resolvedCount(items) {
  return items.length - outstandingItems(items).length;
}

export function dismissedCount(items) {
  return items.filter((item) => item.resolution === RESOLUTION.dismissed).length;
}
