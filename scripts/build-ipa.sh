#!/bin/bash
# Builds MiniWatts as an .ipa.
#
#   ./scripts/build-ipa.sh              unsigned  — for distribution
#   TEAM_ID=XXXXXXXXXX ./scripts/build-ipa.sh signed
#   TEAM_ID=XXXXXXXXXX ./scripts/build-ipa.sh ad-hoc
#
# Unsigned is the default and is what CI publishes. It carries no signing
# identity, no provisioning profile and no team ID, so nothing about whoever
# built it ends up in the file. Whoever installs it signs it themselves with
# their own Apple ID — through Sideloadly, AltStore, SideStore or Xcode.
#
# The signed modes are for installing on your own device from your own machine,
# and need TEAM_ID in the environment. Nothing here has a default team: a team
# ID identifies a person or an organisation and does not belong in a repository.
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="MiniWatts"
PROJECT="MiniWatts.xcodeproj"
BUILD_DIR="build"
DERIVED="$BUILD_DIR/DerivedData"
ARCHIVE="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
# Override to sideload under a bundle id your own Apple ID can claim.
BUNDLE_ID="${BUNDLE_ID:-}"

# The version comes from git, so a release is one step: tag and push. Nothing in the
# project file has to be edited first.
#   MARKETING_VERSION        the highest v* tag on HEAD, without its "v"; on an untagged
#                            commit, the nearest tag behind it. Export it to override —
#                            CI does, from the tag that triggered the run.
#   CURRENT_PROJECT_VERSION  the number of commits reachable from HEAD: it only grows on
#                            master, and is the same locally and in CI as long as CI
#                            checks out full history.
# With no tags, or no git, both fall back to whatever the project file says.
if [ -z "${MARKETING_VERSION:-}" ]; then
  tag=$(git tag --points-at HEAD --list 'v*' 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$tag" ] || tag=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
  [ -z "$tag" ] || MARKETING_VERSION="${tag#v}"
fi
if [ -z "${CURRENT_PROJECT_VERSION:-}" ]; then
  CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD 2>/dev/null || true)
fi

MODE="${1:-unsigned}"
case "$MODE" in
  unsigned) ;;
  signed|development|debugging) METHOD="debugging" ;;
  ad-hoc|adhoc|release-testing) METHOD="release-testing" ;;
  *) echo "usage: $0 [unsigned|signed|ad-hoc]" >&2; exit 1 ;;
esac

# Checked before anything is deleted: a missing TEAM_ID should not cost you the
# artifact from the previous run on its way to an error message.
[ "$MODE" = "unsigned" ] || : "${TEAM_ID:?set TEAM_ID to your Apple Developer team, e.g. TEAM_ID=ABCDE12345 $0 $MODE}"

rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR"

overrides=()
[ -n "$BUNDLE_ID" ] && overrides+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID")
[ -z "${MARKETING_VERSION:-}" ] || overrides+=("MARKETING_VERSION=$MARKETING_VERSION")
[ -z "${CURRENT_PROJECT_VERSION:-}" ] || overrides+=("CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION")
echo "==> Version ${MARKETING_VERSION:-(project file)} build ${CURRENT_PROJECT_VERSION:-(project file)}"

# Swift bakes absolute source and intermediate paths into the binary through
# debug info and #file metadata, so an unsigned build still shipped the builder's
# home directory. Remap the repository root to a fixed stand-in; DerivedData sits
# under it, so both the source and the intermediate paths are covered.
REMAP=(
  "OTHER_SWIFT_FLAGS=-file-prefix-map $PWD=/MiniWatts"
  "OTHER_CFLAGS=-ffile-prefix-map=$PWD=/MiniWatts"
)

if [ "$MODE" = "unsigned" ]; then
  echo "==> Building unsigned"
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS="" \
    DEVELOPMENT_TEAM="" \
    "${REMAP[@]}" \
    ${overrides[@]+"${overrides[@]}"}

  APP="$DERIVED/Build/Products/Release-iphoneos/$SCHEME.app"
  [ -d "$APP" ] || { echo "no .app at $APP" >&2; exit 1; }

  # An .ipa is a zip with the bundle inside a Payload directory. Nothing else is
  # required, and nothing else is included.
  echo "==> Packaging"
  rm -rf "$BUILD_DIR/Payload"
  mkdir -p "$BUILD_DIR/Payload" "$EXPORT_DIR"
  cp -R "$APP" "$BUILD_DIR/Payload/"
  rm -rf "$BUILD_DIR/Payload/$SCHEME.app/_CodeSignature"
  # The linker records the absolute path of every object file in the symbol table
  # (N_OSO debug-map entries), which -file-prefix-map does not reach. Stripping
  # debug and local symbols removes them. The dSYM in DerivedData keeps whatever
  # is needed to symbolicate a crash later.
  xcrun strip -S -x "$BUILD_DIR/Payload/$SCHEME.app/$SCHEME"
  (cd "$BUILD_DIR" && zip -qry "export/$SCHEME-unsigned.ipa" Payload)
  rm -rf "$BUILD_DIR/Payload"
  IPA="$EXPORT_DIR/$SCHEME-unsigned.ipa"
else
  echo "==> Archiving ($METHOD)"
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    "${REMAP[@]}" \
    ${overrides[@]+"${overrides[@]}"}

  cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>$METHOD</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
    <key>stripSwiftSymbols</key><true/>
</dict>
</plist>
PLIST

  echo "==> Exporting"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -exportPath "$EXPORT_DIR" \
    -allowProvisioningUpdates
  IPA="$EXPORT_DIR/$SCHEME.ipa"
fi

if [ "$MODE" = "unsigned" ]; then
  echo
  "$(dirname "$0")/verify-clean.sh" "$IPA"
fi

echo
echo "Done:"
ls -lh "$IPA"
