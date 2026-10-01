// Port of the pure half of macOS/Sources/MarkdownEditor/CritiqueModel.swift.
//
// A critique's state as data: the findings paired with where they point and
// what the author decided about them, in the order the rail shows them.
//
// Kept out of the view for the same reason the Swift keeps it out of the
// SwiftUI: ordering, scoring and staleness are the parts that are easy to get
// quietly wrong, and they are the parts that can be checked without a screen.

import { anchorFindings } from './critique-anchoring.js';
import { critiqueScore, critiqueVerdict } from './critique-score.js';
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
 * How good the draft looks, counting only what is still outstanding.
 *
 * Answering everything returns it to 100 -- the point of the two actions is
 * that the author has said what they meant to say, and the score should agree
 * with them rather than keep score against them.
 */
export function scoreFor(items) {
  return critiqueScore(outstandingItems(items).map((item) => item.finding));
}

export function verdictFor(items) {
  return critiqueVerdict(scoreFor(items));
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
