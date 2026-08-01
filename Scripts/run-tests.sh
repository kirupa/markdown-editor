#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if swift -e 'import Foundation; import Testing' >/dev/null 2>&1; then
  exec swift test --package-path "$ROOT"
fi

FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ ! -d "$FRAMEWORKS/Testing.framework" ]]; then
  echo "Swift Testing is unavailable. Install or select a current Xcode toolchain." >&2
  exit 1
fi

exec swift test \
  --package-path "$ROOT" \
  -Xswiftc -F \
  -Xswiftc "$FRAMEWORKS" \
  -Xswiftc -Xfrontend \
  -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F \
  -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath \
  -Xlinker "$FRAMEWORKS"
