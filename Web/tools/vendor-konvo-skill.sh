#!/usr/bin/env bash
#
# Vendors the KONVO skill's critique pass into Web/skill/.
#
# The macOS app reads the skill out of the checkout in the reader's home
# directory. A web server has no such checkout, and fetching one at request
# time would make every critique depend on GitHub being reachable and would
# leave nothing to review in a diff. So the pass is committed here and shipped
# with the deploy.
#
# That has a consequence worth stating plainly rather than discovering: the web
# build's skill updates when this runs and the result is deployed, not when the
# reader presses something. The version file records which commit was vendored
# so the app can say so on screen instead of implying it is current.
#
#     Web/tools/vendor-konvo-skill.sh [path-to-skill-checkout]
#
# Defaults to ~/.copilot/skills/konvo.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill="${1:-$HOME/.copilot/skills/konvo}"
destination="$here/../skill"

if [[ ! -f "$skill/SKILL.md" ]]; then
  echo "error: no SKILL.md under $skill" >&2
  exit 1
fi

mkdir -p "$destination"

# The same extraction the Swift does: from "## Critique" to the next heading at
# the same level. Done in PHP rather than sed so there is exactly one
# implementation of the rule, and the server reads what this wrote through the
# same code.
php -r '
require $argv[1] . "/../src/KonvoSkill.php";
$markdown = file_get_contents($argv[2]);
$pass = MarkdownEditor\KonvoSkill::critiquePass($markdown);
if ($pass === null) {
    fwrite(STDERR, "error: no \"## Critique\" section in SKILL.md\n");
    exit(1);
}
file_put_contents($argv[3] . "/critique-pass.md", $pass . "\n");
printf("Wrote %d characters to %s/critique-pass.md\n", strlen($pass), $argv[3]);
' "$here" "$skill/SKILL.md" "$destination"

# The version, so the app can say which copy is answering rather than implying
# it is whatever is newest.
if git -C "$skill" rev-parse --git-dir >/dev/null 2>&1; then
  {
    git -C "$skill" log -1 --format='%h'
    git -C "$skill" log -1 --format='%cI'
    git -C "$skill" log -1 --format='%s'
  } > "$destination/version.txt"
  echo "Vendored from $(git -C "$skill" log -1 --format='%h %s')"
else
  printf 'unknown\n\nnot a git checkout\n' > "$destination/version.txt"
  echo "note: $skill is not a git checkout, so no version was recorded."
fi
