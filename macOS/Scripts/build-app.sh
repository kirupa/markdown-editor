#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="Markdown Editor"
EXECUTABLE_NAME="MarkdownEditor"
APP_DIR="$ROOT/build/$APP_NAME.app"

swift build \
  --package-path "$ROOT" \
  --configuration "$CONFIGURATION" \
  --product "$EXECUTABLE_NAME"

BIN_DIR="$(
  swift build \
    --package-path "$ROOT" \
    --configuration "$CONFIGURATION" \
    --show-bin-path
)"

rm -rf -- "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE_NAME" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
cp "$ROOT/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/Packaging/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ROOT/Packaging/MarkdownDocument.icns" "$APP_DIR/Contents/Resources/MarkdownDocument.icns"

# SwiftPM emits one <Package>_<Target>.bundle beside the executable for every
# target that declares `resources:`, and `Bundle.module` looks for it in
# Contents/Resources. No target declares any today, so this copies nothing —
# which is exactly why it is here. Without it, the first target to gain a
# resource would still build and sign cleanly and then trap on launch, at the
# `fatalError` inside the generated `Bundle.module`, with nothing in the build
# output pointing at the cause.
while IFS= read -r bundle; do
  cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done < <(find "$BIN_DIR" -maxdepth 1 -type d -name '*.bundle')

chmod 755 "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
codesign --force --deep --sign - --timestamp=none "$APP_DIR" >/dev/null
codesign --verify --deep --strict "$APP_DIR"

printf 'Built %s\n' "$APP_DIR"
