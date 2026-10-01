// Port of Shared/Sources/MarkdownEditorCore/CritiqueReport.swift.
//
// What an editorial pass over a draft has to say about it: a job read, an
// overall judgement, findings anchored to the smallest passage that proves
// them, patterns that repeat, and the choices worth keeping.
//
// The decoding is deliberately forgiving. What arrives from a language model
// is text, and a report that is 90% right should still be shown rather than
// thrown away over one unexpected field.

/** Sort order for a rail that shows the worst first. */
export const SEVERITY_RANK = { high: 0, medium: 1, low: 2 };

export const SEVERITY_LABEL = { high: 'High', medium: 'Medium', low: 'Low' };

/**
 * Reads a severity from whatever the model actually wrote.
 *
 * Forgiving on purpose. The label is decoration around the finding, and
 * throwing away a real editorial point because it arrived as "High" or
 * "critical" would be a poor trade.
 */
export function parseSeverity(raw) {
  const cleaned = String(raw ?? '').trim().toLowerCase();
  switch (cleaned) {
    case 'high':
    case 'critical':
    case 'major':
    case 'blocker':
      return 'high';
    case 'low':
    case 'minor':
    case 'nit':
    case 'polish':
      return 'low';
    default:
      return 'medium';
  }
}

/** What to show under "Why" -- the advice, whichever form it came in. */
export function findingAdvice(finding) {
  const candidates = [finding.fix, finding.direction]
    .filter((value) => typeof value === 'string')
    .map((value) => value.trim())
    .filter((value) => value !== '');
  return candidates.length > 0 ? candidates[0] : null;
}

/** Whether the advice is a correction to apply or a direction to consider. */
export function findingAdviceLabel(finding) {
  const trimmedFix = String(finding.fix ?? '').trim();
  return trimmedFix === '' ? 'Direction' : 'Fix';
}

export function reportIsEmpty(report) {
  if (!report) return true;
  return (
    report.findings.length === 0 &&
    report.repeatedPatterns.length === 0 &&
    report.keep.length === 0 &&
    report.whatWorks.length === 0 &&
    report.whatDoesNotWork.length === 0 &&
    report.jobRead === '' &&
    report.overall === ''
  );
}

/**
 * The same report about the same draft, carrying a different set of findings.
 *
 * For a critique that re-read only part of the draft: the summary is this
 * run's, because it was asked about the whole thing either way, while the
 * findings are the surviving notes plus the new ones.
 */
export function replacingFindings(report, findings) {
  return { ...report, findings };
}

let nextID = 0;
/**
 * Identity for a finding, so the rail can key cards and highlights by it.
 *
 * A counter rather than a hash of the finding's own text: two findings can
 * quote the same passage with the same category, and a hash would collide
 * exactly when the rail most needs to tell them apart.
 */
export function freshID(prefix = 'finding') {
  nextID += 1;
  return `${prefix}-${nextID}`;
}

// MARK: - Reading a report out of a model's reply

export class CritiqueDecodeError extends Error {
  constructor(kind, detail) {
    super(detail);
    this.name = 'CritiqueDecodeError';
    this.kind = kind;
  }
}

/**
 * The first balanced `{...}` run in `text`, ignoring braces inside strings.
 *
 * Counting braces without minding string literals is the obvious version and
 * it is wrong: a finding whose quote contains a brace -- entirely possible in
 * a draft about code -- would end the object early and lose every finding
 * after it.
 */
export function extractJSONObject(text) {
  const characters = Array.from(String(text ?? ''));
  let depth = 0;
  let start = null;
  let inString = false;
  let escaped = false;

  for (let index = 0; index < characters.length; index += 1) {
    const character = characters[index];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (character === '\\') {
        escaped = true;
      } else if (character === '"') {
        inString = false;
      }
      continue;
    }
    if (character === '"') {
      inString = true;
    } else if (character === '{') {
      if (depth === 0) start = index;
      depth += 1;
    } else if (character === '}') {
      if (depth === 0) continue;
      depth -= 1;
      if (depth === 0 && start !== null) {
        return characters.slice(start, index + 1).join('');
      }
    }
  }
  return null;
}

/**
 * Reads a report out of whatever the model replied.
 *
 * The reply is not guaranteed to be only JSON even when the prompt asks for
 * only JSON: a fence, a sentence of preamble, or a trailing summary line are
 * all things a model does. So the object is *found* in the text rather than
 * assumed to be all of it.
 */
export function decodeCritiqueReport(reply) {
  const json = extractJSONObject(reply);
  if (json === null) {
    throw new CritiqueDecodeError('noJSONFound', 'nothing in the reply looked like JSON');
  }
  let parsed;
  try {
    parsed = JSON.parse(json);
  } catch (error) {
    throw new CritiqueDecodeError('malformedJSON', error.message);
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new CritiqueDecodeError('malformedJSON', 'the reply is not a JSON object');
  }
  return reportFrom(parsed);
}

function reportFrom(object) {
  const keep = arrayOfStrings(object.keep);
  const whatWorks = arrayOfStrings(object.whatWorks);
  return {
    jobRead: string(object.jobRead) ?? '',
    overall: string(object.overall) ?? '',
    // `keep` is the older name for the same idea, and saved critiques still
    // carry it. Falling back keeps a history written by an earlier build
    // readable rather than blank.
    whatWorks: whatWorks.length > 0 ? whatWorks : keep,
    whatDoesNotWork: arrayOfStrings(object.whatDoesNotWork),
    findings: asArray(object.findings)
      .filter((entry) => entry && typeof entry === 'object')
      .map(findingFrom)
      .filter((entry) => entry !== null),
    repeatedPatterns: asArray(object.repeatedPatterns)
      .filter((entry) => entry && typeof entry === 'object')
      .map(patternFrom)
      .filter((entry) => entry !== null),
    keep,
  };
}

function findingFrom(object) {
  const quote = string(object.quote) ?? '';
  const why = string(object.why) ?? '';
  // A finding with neither a passage nor a reason has nothing to say and
  // nowhere to say it, so it is dropped rather than shown as an empty card.
  if (quote === '' && why === '') return null;
  return {
    id: freshID(),
    severity: parseSeverity(string(object.severity)),
    category: string(object.category) ?? 'Note',
    needsVerification: boolean(object.needsVerification),
    location: string(object.location) ?? '',
    quote,
    why,
    fix: string(object.fix),
    direction: string(object.direction),
  };
}

function patternFrom(object) {
  const pattern = string(object.pattern);
  if (pattern === null || pattern === '') return null;
  return { id: freshID('pattern'), pattern, locations: arrayOfStrings(object.locations) };
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function string(value) {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed === '' ? null : trimmed;
}

function arrayOfStrings(value) {
  return asArray(value)
    .map(string)
    .filter((entry) => entry !== null);
}

/** Accepts the several ways a model writes a boolean. */
function boolean(value) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  if (typeof value === 'string') return ['true', 'yes', '1'].includes(value.toLowerCase());
  return false;
}
