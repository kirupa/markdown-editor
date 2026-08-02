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
chmod 755 "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
codesign --force --deep --sign - --timestamp=none "$APP_DIR" >/dev/null
codesign --verify --deep --strict "$APP_DIR"

printf 'Built %s\n' "$APP_DIR"
