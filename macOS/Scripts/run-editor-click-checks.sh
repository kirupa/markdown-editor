#!/bin/bash
# Builds and runs the editor click checks.
#
# Hosts the real SwiftUI `MarkdownEditorView` and asks the window which view a
# click on a picture would reach. The geometry checks build a bare text view,
# so they cannot see a floating explorer or gripper covering the preview; this
# can.
#
# Compiles the real app sources — minus the `@main` entry point, which would
# collide — linking against the object files SPM has already produced.
#
# The window it opens is placed far off-screen and never ordered front.

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
swiftc -parse-as-library -o "$OUT/check-editor-clicks" \
    $SOURCES Scripts/check-editor-clicks.swift $OBJECTS \
    -I "$BIN_DIR/Modules"

"$OUT/check-editor-clicks"
