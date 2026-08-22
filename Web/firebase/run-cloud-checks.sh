#!/bin/bash
# Runs the app's real cloud store against a real Firestore.
#
#     Web/firebase/run-cloud-checks.sh
#
# Every cloud test in the suite runs against an in-memory double. That is a
# deliberate design -- it is what makes the backend's decisions testable
# offline -- but it means those tests are only as good as the double's
# resemblance to Firestore, which nothing checked. `check-cloud.mjs` puts the
# same sequences through both and compares, and covers the parts only a real
# Firestore has: the over-matching range query, batch atomicity, and live
# updates delivered between two independent clients.
#
# Requires a JDK and the Firebase CLI, same as run-rules-checks.sh:
#
#     brew install openjdk && npm install -g firebase-tools
#
# The Firebase SDK is fetched once into a gitignored cache by `vendor-sdk.mjs`,
# because the app imports it from a CDN URL that node will not resolve.
# `sdk-boot.mjs` maps that URL onto the cache, so the app's own modules are
# what run -- including `loadFirebase`'s caching and `openFirestore`'s fallback
# when persistence is unavailable, which in node it always is.

set -euo pipefail

cd "$(dirname "$0")"

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

# Fetches only on a cache miss, so this is free after the first run. It needs
# the network exactly once per pinned SDK version.
node vendor-sdk.mjs >/dev/null

exec firebase emulators:exec \
    --project "${MDE_RULES_PROJECT:-demo-markdown-editor}" \
    --only auth,firestore,storage \
    "node --import ./sdk-boot.mjs check-cloud.mjs"
