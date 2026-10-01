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
// It scores what is *outstanding*, so completing or dismissing everything
// returns exactly 100. That is the point of the two actions: the author has
// said what they meant to say, and the score should agree with them rather
// than keep score against them.

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

/** The score for a set of outstanding findings. */
export function critiqueScore(findings) {
  const penalty = findings.reduce((total, finding) => total + severityWeight(finding.severity), 0);
  return scoreForPenalty(penalty);
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
 */
export function critiqueVerdict(score) {
  if (score >= 100) return 'Ready';
  if (score >= 85) return 'Nearly there';
  if (score >= 60) return 'Solid, with work to do';
  if (score >= 35) return 'Needs a pass';
  return 'Needs a rewrite';
}
