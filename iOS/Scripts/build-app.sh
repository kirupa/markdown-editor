#!/bin/bash
#
# Builds "Markdown Editor.app" for the iOS Simulator without Xcode.
#
# The normal way to build this is to open MarkdownEditor.xcodeproj, and that
# is what most people should do. This script exists so the app can be built,
# installed, and run from a terminal on a machine where `xcodebuild` is
# unavailable — including one where Xcode is installed but its licence has not
# been accepted, which gates `xcodebuild` and `simctl` but not `swiftc`.
#
# It produces the same thing the Xcode project does: the shared package
# compiled for the simulator, the app sources compiled against it, and a real
# bundle with a compiled asset catalog and an ad-hoc signature.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
APP_NAME="Markdown Editor"
EXECUTABLE_NAME="MarkdownEditor"
APP_DIR="$ROOT/build/$APP_NAME.app"
DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-17.0}"

# Prefer the Command Line Tools toolchain: it can compile against the iOS SDK
# and, unlike the Xcode one, does not refuse to run before the licence is
# accepted. Callers who want the Xcode toolchain can set DEVELOPER_DIR.
TOOLCHAIN="${MDE_TOOLCHAIN:-/Library/Developer/CommandLineTools}"
if [ ! -x "$TOOLCHAIN/usr/bin/swiftc" ]; then
  TOOLCHAIN="$(xcode-select -p)"
fi

XCODE_DIR="${MDE_XCODE:-/Applications/Xcode.app/Contents/Developer}"
PLATFORM="$XCODE_DIR/Platforms/iPhoneSimulator.platform"
SDK="$PLATFORM/Developer/SDKs/iPhoneSimulator.sdk"

if [ ! -d "$SDK" ]; then
  printf 'error: no iOS Simulator SDK at %s\n' "$SDK" >&2
  printf 'Install Xcode, or set MDE_XCODE to its Contents/Developer.\n' >&2
  exit 1
fi

ARCH="${MDE_ARCH:-$(uname -m)}"
TARGET="$ARCH-apple-ios$DEPLOYMENT_TARGET-simulator"
WORK="$ROOT/build/intermediates"

rm -rf -- "$APP_DIR" "$WORK"
mkdir -p "$WORK"

# 1. The shared package, compiled for the simulator.
#
# SwiftPM has no iOS destination of its own, and `-Xswiftc -sdk` does not work
# because SwiftPM appends its own macOS -sdk afterwards and wins. A
# destination file is the supported way to say this.
cat > "$WORK/destination.json" <<JSON
{
  "version": 1,
  "target": "$TARGET",
  "sdk": "$SDK",
  "toolchain-bin-dir": "$TOOLCHAIN/usr/bin",
  "extra-cc-flags": ["-target", "$TARGET"],
  "extra-swiftc-flags": ["-target", "$TARGET"],
  "extra-cpp-flags": ["-target", "$TARGET"]
}
JSON

DEVELOPER_DIR="$TOOLCHAIN" "$TOOLCHAIN/usr/bin/swift" build \
  --package-path "$REPO/Shared" \
  --destination "$WORK/destination.json" \
  --configuration release

SHARED_BIN="$REPO/Shared/.build/$ARCH-apple-ios-simulator/release"

# SwiftPM leaves an "automatic" library product as loose object files rather
# than an archive, because it normally decides how to link at the point of
# use. Gather them into one static library to link against.
find "$SHARED_BIN/MarkdownEditorCore.build" "$SHARED_BIN/MarkdownEditorUI.build" \
  -name '*.o' -print0 | xargs -0 "$TOOLCHAIN/usr/bin/libtool" \
  -static -o "$WORK/libMarkdownEditorKit.a"

# 2. The app itself.
mkdir -p "$APP_DIR"

DEVELOPER_DIR="$TOOLCHAIN" "$TOOLCHAIN/usr/bin/swiftc" \
  -target "$TARGET" \
  -sdk "$SDK" \
  -O \
  -module-name "$EXECUTABLE_NAME" \
  -I "$SHARED_BIN/Modules" \
  -L "$WORK" \
  -lMarkdownEditorKit \
  -o "$APP_DIR/$EXECUTABLE_NAME" \
  "$ROOT/Sources/MarkdownEditorIOS"/*.swift

# 3. The bundle.
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Info.plist"

# Any resource bundle the shared package emitted. An iOS app bundle is flat,
# so `Bundle.module` looks for these beside the executable rather than in a
# Resources folder. No shared target declares `resources:` today, so this
# copies nothing — see the same loop in ../macOS/Scripts/build-app.sh for why
# it is worth having anyway.
while IFS= read -r bundle; do
  cp -R "$bundle" "$APP_DIR/"
done < <(find "$SHARED_BIN" -maxdepth 1 -type d -name '*.bundle')
plutil -replace CFBundleExecutable -string "$EXECUTABLE_NAME" \
  "$APP_DIR/Info.plist"
plutil -replace MinimumOSVersion -string "$DEPLOYMENT_TARGET" \
  "$APP_DIR/Info.plist"
plutil -replace DTPlatformName -string iphonesimulator "$APP_DIR/Info.plist"
plutil -replace CFBundleSupportedPlatforms -json '["iPhoneSimulator"]' \
  "$APP_DIR/Info.plist"
plutil -lint "$APP_DIR/Info.plist" >/dev/null

# actool lives in Xcode rather than the Command Line Tools. It needs Xcode's
# first-launch packages, which the licence prompt installs, so it may not work
# even though swiftc does. The app runs either way; it just has no icon until
# it is built through Xcode.
ACTOOL="$XCODE_DIR/usr/bin/actool"
if [ -x "$ACTOOL" ] && "$ACTOOL" \
  --compile "$APP_DIR" \
  --platform iphonesimulator \
  --minimum-deployment-target "$DEPLOYMENT_TARGET" \
  --app-icon AppIcon \
  --output-partial-info-plist "$WORK/assets.plist" \
  --output-format human-readable-text \
  "$ROOT/Resources/Assets.xcassets" >"$WORK/actool.log" 2>&1 \
  && [ -f "$APP_DIR/Assets.car" ]; then
  plutil -replace CFBundleIconName -string AppIcon "$APP_DIR/Info.plist"
else
  printf 'note: asset catalog not compiled, so the app has no icon.\n' >&2
  sed -n 's/^/      /p' "$WORK/actool.log" 2>/dev/null | grep . >&2 || true
fi

codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null
codesign --verify --strict "$APP_DIR"

printf 'Built %s (%s)\n' "$APP_DIR" "$TARGET"
