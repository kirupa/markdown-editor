#!/bin/bash
# Builds and runs the VoiceOver checks.
#
# Reads what VoiceOver is told about every control in the editor window, the
# critique rail, the theme popover, the file explorer and the welcome window,
# from the real views' own accessibility tree.
#
# Compiles the real app sources — minus the `@main` entry point, which would
# collide — linking against the object files SPM has already produced.
#
# The windows it opens are fully transparent and ordered behind everything
# else. Nothing is asked of another process, so it runs behind a locked screen.

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG=debug
BIN_DIR="$(swift build --configuration "$CONFIG" --show-bin-path)"

echo "building the app sources for checking…"
swift build --configuration "$CONFIG" >/dev/null

SOURCES=$(find Sources/MarkdownEditor -name '*.swift' ! -name 'MarkdownEditorApp.swift')

# Two build layouts. SwiftPM's own keeps each module's objects in
# `<Module>.build/` and the interfaces in `Modules/`; the newer swift-build one
# links each module into a single `<Module>.o` beside its `.swiftmodule`.
if [ -d "$BIN_DIR/Modules" ]; then
    MODULES="$BIN_DIR/Modules"
    OBJECTS=$(find "$BIN_DIR" -name '*.o' -path '*.build*' \
        \( -path '*MarkdownEditorCore.build*' \
        -o -path '*MarkdownEditorUI.build*' \
        -o -path '*MarkdownEditorContract.build*' \
        -o -path '*MarkdownEditorCloud.build*' \) 2>/dev/null)
else
    MODULES="$BIN_DIR"
    OBJECTS=$(find "$BIN_DIR" -maxdepth 1 -name 'MarkdownEditor*.o' 2>/dev/null)
fi

if [ -z "$OBJECTS" ]; then
    echo "could not find the shared package objects under $BIN_DIR" >&2
    exit 1
fi

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# shellcheck disable=SC2086
swiftc -parse-as-library -o "$OUT/check-voiceover" \
    $SOURCES Scripts/check-voiceover.swift $OBJECTS \
    -I "$MODULES"

"$OUT/check-voiceover"
