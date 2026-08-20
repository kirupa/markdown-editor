#!/bin/bash
# Builds and runs the split-pane coordination checks.
#
# `MarkdownEditorSession` lives in the app's executable target, which no test
# target can import. Rather than leave it untested, this compiles the real app
# sources — minus the `@main` entry point, which would collide — together with
# Scripts/check-session.swift, linking against the object files SPM has
# already produced for the shared package.

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG=debug
BIN_DIR="$(swift build --configuration "$CONFIG" --show-bin-path)"

echo "building the app sources for checking…"
swift build --configuration "$CONFIG" >/dev/null

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

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# shellcheck disable=SC2086
swiftc -parse-as-library -o "$OUT/check-session" \
    $SOURCES Scripts/check-session.swift $OBJECTS \
    -I "$BIN_DIR/Modules"

"$OUT/check-session"
