#!/bin/bash
# Builds and runs the formatting availability checks.
#
# Hosts the real SwiftUI `MarkdownEditorView` on a document with a fence, a
# quote and a code span in it, and runs the formatting commands the toolbar
# runs. The unit tests hold the rule with source offsets; this is the only
# check that exercises the half a person actually uses — a selection made in
# the rendered pane, where the fence lines and the `> ` markers are not on
# screen, travelling back through the render model before any command sees it.
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
# The shared package's compiled code, in whichever shape the build system
# left it. The current one merges each library target into a single object
# beside the product; older ones left the per-file objects in the target's
# own `.build` folder. Take the merged objects when they are there.
OBJECTS=$(ls "$BIN_DIR"/MarkdownEditorCore.o "$BIN_DIR"/MarkdownEditorUI.o 2>/dev/null)
if [ -z "$OBJECTS" ]; then
    OBJECTS=$(find "$BIN_DIR" -name '*.o' -path '*.build*' \
        \( -path '*MarkdownEditorCore*' \
        -o -path '*MarkdownEditorUI*' \) 2>/dev/null)
fi

if [ -z "$OBJECTS" ]; then
    echo "could not find the shared package objects under $BIN_DIR" >&2
    exit 1
fi

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# shellcheck disable=SC2086
swiftc -parse-as-library -o "$OUT/check-formatting-availability" \
    $SOURCES Scripts/check-formatting-availability.swift $OBJECTS \
    -I "$BIN_DIR/Modules" -I "$BIN_DIR" \
    -F "$BIN_DIR/PackageFrameworks" -F "$BIN_DIR"

"$OUT/check-formatting-availability"
