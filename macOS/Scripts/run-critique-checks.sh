#!/bin/bash
# Builds and runs the end-to-end critique check.
#
# `CritiqueService` lives in the app's executable target, which no test target
# can import. Rather than leave it untested, this compiles the real app
# sources — minus the `@main` entry point, which would collide — together with
# Scripts/check-critique.swift, linking against the object files SPM has
# already produced for the shared package.
#
# This one talks to the real Copilot CLI, so it costs AI credits and takes
# about half a minute. It is deliberately not part of `make test`.

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG=debug
BIN_DIR="$(swift build --configuration "$CONFIG" --show-bin-path)"

echo "building the app sources for checking…"
# SwiftPM prints compiler diagnostics to *stdout*, so sending stdout to
# /dev/null to hide the progress chatter also hides every error, and a failed
# build looks like a check that stopped for no reason. Kept and replayed.
BUILD_LOG=$(mktemp)
OUT=$(mktemp -d)
# One trap, because a second one replaces the first rather than adding to it.
trap 'rm -f "$BUILD_LOG"; rm -rf "$OUT"' EXIT
if ! swift build --configuration "$CONFIG" >"$BUILD_LOG" 2>&1; then
    cat "$BUILD_LOG" >&2
    exit 1
fi

SOURCES=$(find Sources/MarkdownEditor -name '*.swift' ! -name 'MarkdownEditorApp.swift')
OBJECTS=$(find "$BIN_DIR" -name '*.o' -path '*.build*' \
    \( -path '*MarkdownEditorCore.build*' \
    -o -path '*MarkdownEditorUI.build*' \
    -o -path '*MarkdownEditorContract.build*' \
    -o -path '*MarkdownEditorCloud.build*' \) 2>/dev/null)

if [ -z "$OBJECTS" ]; then
    echo "could not find the shared package objects under $BIN_DIR" >&2
    exit 1
fi

# shellcheck disable=SC2086
swiftc -parse-as-library -o "$OUT/check-critique" \
    $SOURCES Scripts/check-critique.swift $OBJECTS \
    -I "$BIN_DIR/Modules"

"$OUT/check-critique" "$@"
