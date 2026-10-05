// Port of Shared/Sources/MarkdownEditorCore/CritiqueScore.swift.
//
// How good the draft looks right now, out of a hundred.
//
// Deliberately a *decaying* score rather than a subtraction. Subtracting a
// fixed cost per finding has two failure modes that both make the number
// useless: a long, thorough critique of a decent draft drives it to zero, and
// once it is at zero the number stops moving however much the author fixes.
// Decay keeps every fix worth something and keeps the worst draft above the
// floor, which is also just true -- no draft anyone bothered to write is worth
// nothing.
//
// It scores what still stands against the draft. A note marked Done stops
// counting, because the author has fixed it. A dismissed note keeps its full
// weight, because dismissing is a decision to leave the passage as it is --
// the problem the critic named is still on the page. Scoring dismissals as
// fixes is what let a draft on the Mac reach "100, Ready" by dismissing all
// eight of its notes while the summary above them still listed three problems,
// and this port did the same until it was brought back in line.
//
// Those summary problems count too, as a low note each: the critic's view of
// what holds the piece back is part of its verdict, and a perfect score next
// to a list of reasons the piece is not perfect reads as a broken number.

/**
 * What one finding costs, before decay.
 *
 * Severity is about reader impact, and the gaps between the three are wide
 * because the consequences are: a false claim breaks the piece, a clumsy
 * sentence slows it down, a typo is a typo.
 */
export function severityWeight(severity) {
  switch (severity) {
    case 'high':
      return 12;
    case 'medium':
      return 5;
    default:
      return 2;
  }
}

/**
 * How fast the score falls. Larger is gentler.
 *
 * Chosen so that one high lands in the low eighties, a typical messy draft --
 * three high and four medium -- lands near forty, and a draft with a dozen
 * serious problems is still in single figures rather than negative.
 */
export const SOFTNESS = 60;

/**
 * What one problem from the summary costs: the same as a low note.
 *
 * Less than a passage-level finding because it is a judgement about the piece
 * in the round, often a restatement of findings already counted, and the
 * author cannot answer it directly. Enough that three of them hold a draft
 * with no notes left at ninety.
 */
export const LISTED_PROBLEM_WEIGHT = 2;

/**
 * The score for the findings still standing against the draft, plus the
 * problems the summary lists.
 */
export function critiqueScore(findings, listedProblems = 0) {
  const penalty =
    findings.reduce((total, finding) => total + severityWeight(finding.severity), 0)
    + Math.max(0, listedProblems) * LISTED_PROBLEM_WEIGHT;
  return scoreForPenalty(penalty);
}

/**
 * Whether a finding answered this way still costs the draft.
 *
 * Only Done clears a note. Dismissed means "leaving it", not "fixed it".
 */
export function countsAgainstScore(resolution) {
  return resolution !== 'completed';
}

export function scoreForPenalty(penalty) {
  if (penalty <= 0) return 100;
  const decayed = 100 * Math.exp(-penalty / SOFTNESS);
  // Never zero: the floor is 1, because a draft with something in it is never
  // worth nothing, and a zero reads as a verdict rather than a measurement.
  return Math.max(1, Math.min(100, Math.round(decayed)));
}

/**
 * A word for the number, so the rail says something rather than only scoring
 * something.
 *
 * "Ready" is a claim about the draft, so it is only made when a critique of
 * the text as it stands found nothing: `isConfirmed` is false when the draft
 * has changed since, or when the hundred was reached by marking notes Done by
 * hand. Either way the author's word is taken for the number, and the verdict
 * asks a fresh critique to agree.
 */
export function critiqueVerdict(score, isConfirmed = true) {
  if (score >= 100) return isConfirmed ? 'Ready' : 'Looks ready';
  if (score >= 85) return 'Nearly there';
  if (score >= 60) return 'Solid, with work to do';
  if (score >= 35) return 'Needs a pass';
  return 'Needs a rewrite';
}
