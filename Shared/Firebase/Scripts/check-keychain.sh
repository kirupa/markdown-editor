#!/bin/bash
#
# Can an ad-hoc-signed .app sign in with FirebaseAuth?
#
# `run-emulator-checks.sh` runs unauthenticated because a plain SwiftPM
# executable cannot sign in: FirebaseAuth persists to the macOS
# data-protection keychain and an unbundled binary has no entitlement for it,
# so `signInAnonymously()` fails with `SecItemAdd (-34018)`.
#
# That is a property of the *binary*, and the shipping app is not one — it is a
# bundle with an identifier, ad-hoc signed by Scripts/build-app.sh. Whether the
# keychain treats it differently decides whether a cloud sign-in screen can
# work on a build that anyone can produce from this repository, so it is worth
# an answer rather than an assumption.
#
# Runs the same sign-in three ways — bare, ad-hoc-signed bundle, and a bundle
# claiming the entitlement — and then narrows *what* is refusing us with a
# fourth, Firebase-free probe that writes to each of the two macOS keychains,
# under both an ad-hoc and an ad-hoc-plus-sandbox signature. The comparisons
# are the point, so everything is always run and every result is printed.
#
#     Shared/Firebase/Scripts/check-keychain.sh
#
# Needs a JDK and the Firebase CLI, like the other emulator scripts.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$ROOT/../.." && pwd)"

for candidate in /opt/homebrew/opt/openjdk/bin /usr/local/opt/openjdk/bin; do
  if [ -x "$candidate/java" ]; then
    PATH="$candidate:$PATH"
    break
  fi
done

if ! command -v java >/dev/null 2>&1 || ! command -v firebase >/dev/null 2>&1; then
  printf 'error: needs a JDK and the Firebase CLI.\n' >&2
  printf '       brew install openjdk && npm install -g firebase-tools\n' >&2
  exit 2
fi

PORT="$(python3 -c "
import json, pathlib
c = json.loads(pathlib.Path('$REPO/Web/firebase/firebase.json').read_text())
print(c['emulators']['auth']['port'])
")"

printf 'Building the probes…\n'
swift build --package-path "$ROOT" --product keychain-probe >/dev/null || exit 1
swift build --package-path "$ROOT" --product keychain-kind >/dev/null || exit 1
BIN="$(swift build --package-path "$ROOT" --show-bin-path)/keychain-probe"
KIND_BIN="$(swift build --package-path "$ROOT" --show-bin-path)/keychain-kind"

# The bundle is assembled here rather than by build-app.sh because it needs to
# hold *this* probe, not the app. Everything that could plausibly matter to the
# keychain is copied from build-app.sh: a bundle identifier, and the same
# `codesign --force --deep --sign -` with no entitlements file.
WORK="$(mktemp -d)"
APP="$WORK/Probe.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Probe"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Probe</string>
  <key>CFBundleIdentifier</key><string>com.kirupa.markdown-editor</string>
  <key>CFBundleName</key><string>Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - --timestamp=none "$APP" 2>/dev/null
codesign --verify --deep --strict "$APP" || exit 1

# A third bundle, claiming the entitlement the error asks for. `SecItemAdd
# (-34018)` says "a required entitlement isn't present", so the obvious next
# move is to present it — and the obvious next move needs testing too, because
# `keychain-access-groups` is a restricted entitlement. Restricted entitlements
# have to be authorized by a provisioning profile, which needs an Apple
# Developer Program team; ad-hoc signing cannot grant one. A binary that claims
# it anyway is killed at exec rather than refused at the call.
ENT_APP="$WORK/Entitled.app"
mkdir -p "$ENT_APP/Contents/MacOS"
cp "$BIN" "$ENT_APP/Contents/MacOS/Probe"
sed 's/<string>Probe<\/string>/<string>Probe<\/string>/' "$APP/Contents/Info.plist" > "$ENT_APP/Contents/Info.plist"
cat > "$WORK/probe.entitlements" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>keychain-access-groups</key>
  <array><string>com.kirupa.markdown-editor</string></array>
</dict>
</plist>
XML
codesign --force --deep --sign - --timestamp=none \
  --entitlements "$WORK/probe.entitlements" "$ENT_APP" 2>/dev/null

cd "$REPO/Web/firebase"
firebase emulators:exec --project demo-kirupa-markdown --only auth "
  echo '--- as a bare executable ---'
  MDE_AUTH_EMULATOR=127.0.0.1:$PORT '$BIN'
  echo \"exit \$?\"
  echo '--- from inside an ad-hoc-signed .app ---'
  MDE_AUTH_EMULATOR=127.0.0.1:$PORT '$APP/Contents/MacOS/Probe'
  echo \"exit \$?\"
  echo '--- from a .app claiming keychain-access-groups ---'
  MDE_AUTH_EMULATOR=127.0.0.1:$PORT '$ENT_APP/Contents/MacOS/Probe'
  echo \"exit \$? (137 is SIGKILL)\"
" 2>&1 | grep -vE '^(i  |✔  |⚠  )'

# Which keychain, and is the signature even the problem? The three runs above
# all fail the same way, which says something is missing but not what. This
# writes to both macOS keychains from one process, under two signatures — plain
# ad-hoc, and ad-hoc plus `app-sandbox`. The sandbox case is worth its own run
# because, unlike `keychain-access-groups`, the sandbox entitlement is *not*
# restricted: ad-hoc signing can grant it, and a sandboxed app gets an implicit
# keychain access group. If that group were enough, native sign-in would need
# no Apple account at all.
kind_bundle() { # <dir> <entitlements-or-empty>
  mkdir -p "$1/Contents/MacOS"
  cp "$KIND_BIN" "$1/Contents/MacOS/Probe"
  cp "$APP/Contents/Info.plist" "$1/Contents/Info.plist"
  if [ -n "$2" ]; then
    codesign --force --deep --sign - --timestamp=none --entitlements "$2" "$1" 2>/dev/null
  else
    codesign --force --deep --sign - --timestamp=none "$1" 2>/dev/null
  fi
}
cat > "$WORK/sandbox.entitlements" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
</dict>
</plist>
XML
kind_bundle "$WORK/Kind.app" ""
kind_bundle "$WORK/KindSandboxed.app" "$WORK/sandbox.entitlements"

printf '\n--- which keychain, from an ad-hoc-signed .app ---\n'
"$WORK/Kind.app/Contents/MacOS/Probe"
printf '\n--- which keychain, ad-hoc + app-sandbox ---\n'
"$WORK/KindSandboxed.app/Contents/MacOS/Probe"

# The case that is not covered above, and the one that would actually settle
# whether native cloud sign-in is reachable. Signing it properly needs an
# identity *and* a provisioning profile authorizing the entitlement for this
# bundle ID, which cannot be synthesized here — so this reports what the
# machine has rather than pretending to test it.
printf '\n--- properly signed ---\n'
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null | grep -c '^ *[0-9]*)')"
if [ "${IDENTITIES:-0}" -eq 0 ]; then
  printf 'not tested: this machine has no code-signing identity.\n'
  printf 'The probes above narrow what such a test would have to grant: not a\n'
  printf 'signature as such, but a keychain access group for the\n'
  printf 'data-protection keychain, which comes from a provisioning profile.\n'
  printf 'If you have signed into Xcode with an Apple ID, a Personal Team\n'
  printf 'certificate may be enough. Build the app through Xcode with\n'
  printf 'automatic signing and Keychain Sharing enabled, and see whether\n'
  printf 'sign-in succeeds — that is the open question in macOS/README.md 16.7.\n'
else
  printf 'not tested, but this machine has %s code-signing identity(ies):\n' "$IDENTITIES"
  security find-identity -v -p codesigning 2>/dev/null | grep '^ *[0-9]*)' | sed 's/^/  /'
  printf 'Worth answering 16.7 with: sign the bundle with one of these plus a\n'
  printf 'profile authorizing keychain-access-groups, and re-run the probe.\n'
fi

rm -rf "$WORK"
