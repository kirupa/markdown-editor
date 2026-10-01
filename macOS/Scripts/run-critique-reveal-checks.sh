#!/bin/bash
# Builds and runs the critique reveal checks.
#
# Hosts the real `RichTextEditor` with a real `CritiqueModel` and asks whether
# selecting a finding puts its passage on screen — on the first selection,
# from a pane that has not been laid out yet, which is the state the reported
# bug lives in. A pane that has already been scrolled through cannot reproduce
# it: `NSTextView` never shrinks its frame once grown.
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
# SwiftPM prints compiler diagnostics to *stdout*, so hiding the progress
# chatter also hides every error. Kept and replayed on failure.
BUILD_LOG=$(mktemp)
OUT=$(mktemp -d)
trap 'rm -f "$BUILD_LOG"; rm -rf "$OUT"' EXIT
if ! swift build --configuration "$CONFIG" >"$BUILD_LOG" 2>&1; then
    cat "$BUILD_LOG" >&2
    exit 1
fi

SOURCES=$(find Sources/MarkdownEditor -name '*.swift' ! -name 'MarkdownEditorApp.swift')
# The two build systems SwiftPM ships lay their output out differently: one
# leaves per-file objects under `.build` with the modules in `Modules/`, the
# other leaves one merged object per target beside the `.swiftmodule` in the
# bin directory. Take whichever is there, or the check fails on the other
# machine for a reason that has nothing to do with what it checks.
OBJECTS=$(ls "$BIN_DIR"/*.o 2>/dev/null || true)
if [ -z "$OBJECTS" ]; then
    OBJECTS=$(find "$BIN_DIR" -name '*.o' -path '*.build*' \
        \( -path '*MarkdownEditorCore*.build*' \
        -o -path '*MarkdownEditorUI*.build*' \
        -o -path '*MarkdownEditorContract*.build*' \
        -o -path '*MarkdownEditorCloud*.build*' \) 2>/dev/null)
fi

if [ -z "$OBJECTS" ]; then
    echo "could not find the shared package objects under $BIN_DIR" >&2
    exit 1
fi

# shellcheck disable=SC2086
swiftc -parse-as-library -o "$OUT/check-critique-reveal" \
    $SOURCES Scripts/check-critique-reveal.swift $OBJECTS \
    -I "$BIN_DIR" -I "$BIN_DIR/Modules"

"$OUT/check-critique-reveal" "$@"
