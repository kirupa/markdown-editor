#!/bin/bash

# Installs the built app into /Applications and registers it with Launch
# Services, so it appears in Finder's Open With menu and can be set as the
# default handler for .md and .markdown files.
#
# The build output under build/ is deliberately unregistered afterwards.
# Leaving both copies registered makes Finder show "Markdown Editor" twice in
# Open With, and lets the association point at a bundle that `make clean`
# deletes.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Markdown Editor"
BUILT_APP="$ROOT/build/$APP_NAME.app"
DESTINATION="${INSTALL_DIR:-/Applications}"
INSTALLED_APP="$DESTINATION/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [ ! -d "$BUILT_APP" ]; then
  printf 'No app at %s. Run `make app` first.\n' "$BUILT_APP" >&2
  exit 1
fi

if [ ! -w "$DESTINATION" ]; then
  printf '%s is not writable. Re-run with sudo, or set INSTALL_DIR.\n' "$DESTINATION" >&2
  exit 1
fi

# A running copy cannot be replaced safely.
if pgrep -f "$INSTALLED_APP/Contents/MacOS/" >/dev/null 2>&1; then
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  sleep 1
fi

rm -rf -- "$INSTALLED_APP"
cp -R "$BUILT_APP" "$INSTALLED_APP"

if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -u "$BUILT_APP" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$INSTALLED_APP"
fi

printf 'Installed %s\n' "$INSTALLED_APP"
printf 'Registered as a handler for .md and .markdown.\n'
