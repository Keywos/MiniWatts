#!/bin/bash
# Checks that an .ipa carries nothing about whoever built it.
#
#   ./scripts/verify-clean.sh build/export/MiniWatts-unsigned.ipa
#
# Every one of these has actually leaked at some point: signing identities are the
# obvious case, but absolute build paths reach the binary twice over — through
# Swift's debug info and #file metadata, and again through the linker's object
# file debug map in the symbol table. The two need different fixes, so both are
# checked here rather than assumed.
set -euo pipefail

IPA="${1:?usage: $0 <path to .ipa>}"
[ -f "$IPA" ] || { echo "no such file: $IPA" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$IPA" -d "$WORK"

APP="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$APP" ] || { echo "no .app inside Payload/" >&2; exit 1; }

fail=0
check() { # description, 0 = clean
  if [ "$2" -eq 0 ]; then printf '  ok    %s\n' "$1"
  else printf '  FAIL  %s\n' "$1"; fail=1; fi
}

echo "Checking $(basename "$IPA")"

# Searched for at any depth, not just at the top of the app: an app extension is a
# bundle of its own, and carries its own signature and profile.
[ -n "$(find "$APP" -name _CodeSignature -print -quit)" ] && r=1 || r=0
check "no code signature" $r
[ -n "$(find "$APP" -name embedded.mobileprovision -print -quit)" ] && r=1 || r=0
check "no provisioning profile" $r

# A home directory in any file means a build path survived.
if grep -rlq "/Users/" "$APP" 2>/dev/null; then
  echo "  FAIL  no absolute build paths"
  echo "        found in:"
  grep -rl "/Users/" "$APP" 2>/dev/null | sed "s|$WORK|...|" | sed 's/^/          /'
  fail=1
else
  check "no absolute build paths" 0
fi

# Team identifiers are ten alphanumerics; look for the Apple keys that carry them.
if grep -rlq "com.apple.developer.team-identifier\|application-identifier" "$APP" 2>/dev/null; then
  r=1; else r=0; fi
check "no team identifier" $r

echo "  info  bundle id: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist" 2>/dev/null || echo '?')"
echo "  info  version:   $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist" 2>/dev/null || echo '?')"
echo "  info  extensions: $(find "$APP" -name '*.appex' -type d | wc -l | tr -d ' ')"

[ "$fail" -eq 0 ] || { echo; echo "This build carries identifying data — do not publish it." >&2; exit 1; }
echo
echo "Clean."
