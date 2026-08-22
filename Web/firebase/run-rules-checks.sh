#!/bin/bash
# Evaluates firestore.rules and storage.rules with Firebase's own rules engine.
#
#     Web/firebase/run-rules-checks.sh
#
# Starts the Firestore, Storage and Auth emulators, runs check-rules.mjs
# against them, and shuts them down again. `emulators:exec` is what makes that
# one step: it owns the whole lifecycle and exits with the command's own status,
# so there is no background process left listening on a port afterwards.
#
# Requires a JDK (the emulators are Java) and the Firebase CLI:
#
#     brew install openjdk && npm install -g firebase-tools
#
# Neither is needed to build or run the editor, and nothing else in the
# repository depends on them -- this is the one check that cannot be done
# without them, because transcribing a rule is not the same as evaluating it.
#
# The project id begins with `demo-`, which the CLI treats as offline-only: no
# real project is contacted and no credentials are needed. In particular the
# Auth emulator issues ID tokens to anyone who asks, which is the only reason
# these rules are testable at all -- the live project has just the Google
# provider enabled, so a script cannot sign in to it.

set -euo pipefail

cd "$(dirname "$0")"

# Homebrew's openjdk is keg-only, so it is deliberately not on the default
# PATH. Add it if it is there and nothing else has already provided a JDK.
if ! command -v java >/dev/null 2>&1 || ! java -version >/dev/null 2>&1; then
    for candidate in /opt/homebrew/opt/openjdk/bin /usr/local/opt/openjdk/bin; do
        if [ -x "$candidate/java" ]; then
            PATH="$candidate:$PATH"
            export PATH
            break
        fi
    done
fi

if ! java -version >/dev/null 2>&1; then
    echo "the Firebase emulators need a JDK; install one with: brew install openjdk" >&2
    exit 2
fi

if ! command -v firebase >/dev/null 2>&1; then
    echo "the Firebase CLI is missing; install it with: npm install -g firebase-tools" >&2
    exit 2
fi

exec firebase emulators:exec \
    --project "${MDE_RULES_PROJECT:-demo-markdown-editor}" \
    --only auth,firestore,storage \
    "node check-rules.mjs"
