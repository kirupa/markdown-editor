#!/bin/bash
#
# Runs the native Firestore adapter against an emulated Firestore.
#
# `swift test` in ../ covers the cloud *decisions* against an in-memory double,
# which is what keeps it fast and offline. This covers the adapter underneath:
# the field names it writes, whether the subtree range query needs its filter,
# whether a batch is atomic, and whether a listener fires. Those are properties
# of Firestore, so they need one.
#
#     Shared/Firebase/run-emulator-checks.sh
#
# It runs unauthenticated against permissive rules; emulator/adapter.rules
# explains why, and why the shipped rules are verified elsewhere instead.
#
# Needs a JDK (the emulators are Java) and the Firebase CLI. Homebrew's openjdk
# is keg-only, so it is looked for where Homebrew puts it rather than only on
# PATH.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for candidate in /opt/homebrew/opt/openjdk/bin /usr/local/opt/openjdk/bin; do
  if [ -x "$candidate/java" ]; then
    PATH="$candidate:$PATH"
    break
  fi
done

if ! command -v java >/dev/null 2>&1; then
  printf 'error: the Firebase emulators need a JDK, and there is none on PATH.\n' >&2
  printf '       brew install openjdk\n' >&2
  exit 2
fi

if ! command -v firebase >/dev/null 2>&1; then
  printf 'error: the Firebase CLI is not installed.\n' >&2
  printf '       npm install -g firebase-tools\n' >&2
  exit 2
fi

# Read the port out of the emulator configuration rather than repeating it, so
# a change there cannot leave this pointing at nothing.
PORT="$(python3 -c "
import json, pathlib
c = json.loads(pathlib.Path('$ROOT/emulator/firebase.json').read_text())
print(c['emulators']['firestore']['port'])
")"

printf 'Building the check…\n'
swift build --package-path "$ROOT" --product firebase-emulator-check >/dev/null

BIN="$(swift build --package-path "$ROOT" --show-bin-path)"

# `emulators:exec` owns the lifetime of the emulator for exactly one command,
# which is what keeps a mutation sweep honest: `emulators:start` piped into
# anything that exits early is killed by SIGPIPE, and every check then fails
# for want of a Firestore, which looks exactly like a mutant being caught.
cd "$ROOT/emulator"
exec firebase emulators:exec \
  --project demo-kirupa-markdown \
  --only firestore \
  "MDE_FIRESTORE_EMULATOR=127.0.0.1:$PORT '$BIN/firebase-emulator-check'"
