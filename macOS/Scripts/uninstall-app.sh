#!/bin/bash

# Removes the installed app and drops its Launch Services registration, so
# .md files fall back to whichever other handler macOS picks.

set -euo pipefail

APP_NAME="Markdown Editor"
DESTINATION="${INSTALL_DIR:-/Applications}"
INSTALLED_APP="$DESTINATION/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [ ! -d "$INSTALLED_APP" ]; then
  printf 'Nothing installed at %s.\n' "$INSTALLED_APP"
  exit 0
fi

if pgrep -f "$INSTALLED_APP/Contents/MacOS/" >/dev/null 2>&1; then
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  sleep 1
fi

if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -u "$INSTALLED_APP" >/dev/null 2>&1 || true
fi

rm -rf -- "$INSTALLED_APP"
printf 'Removed %s\n' "$INSTALLED_APP"
