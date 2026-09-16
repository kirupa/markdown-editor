#!/bin/bash
# Builds and runs the window checks.
#
# Asks a real document window how wide it made itself. The geometry is unit
# tested and needs no screen; what needs one is whether the window uses the
# answer, which is exactly where the clipped-rail bug lived.
#
# Compiles the real app sources — minus the `@main` entry point, which would
# collide — linking against the object files SPM has already produced.
#
# The window it opens is fully transparent and ordered behind everything else.
# Set MDE_WINDOW_PNG to a path to also write out what it drew.

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
swiftc -parse-as-library -o "$OUT/check-window" \
    $SOURCES Scripts/check-window.swift $OBJECTS \
    -I "$BIN_DIR/Modules"

"$OUT/check-window"
