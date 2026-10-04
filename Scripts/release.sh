#!/bin/bash
# Build, ad-hoc sign and package a release (PLAN §6.3). No Developer ID, no notarization: distribution is
# GitHub Releases (zip for Sparkle, dmg for humans/Homebrew) + the xuanji86/homebrew-tap cask.
#
#   Scripts/release.sh <version>             dry run (default): everything is produced under build/release/<version>/,
#                                            nothing is uploaded or pushed
#   Scripts/release.sh <version> --publish   also creates a DRAFT GitHub Release; if $TAP_DIR points at a checkout
#                                            of the tap, also commits + pushes the cask there
#
# <version> is the marketing version, e.g. 0.1.0 or 0.1.0-beta.1 (no leading "v"; the tag is v<version>).
# The build number (sparkle:version / CFBundleVersion) is the commit count, so it only grows along main.
# lazy: breaks in a shallow clone (count is too small); fetch full history before releasing.
#
# Sparkle EdDSA: sign_update reads the private key from the login keychain (made once with Sparkle's
# `generate_keys`). Without it the dry run still works but the appcast item is unsigned and --publish refuses.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=xuanji86/MacDown2.0
APP=MacDown2
MIN_SYSTEM=26.0

die() { echo "release.sh: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

VERSION=""
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --dry-run) PUBLISH=0 ;;
    -*) die "unknown option $arg" ;;
    *) [ -z "$VERSION" ] || die "version given twice"; VERSION="$arg" ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "usage: $0 <version, e.g. 0.1.0> [--dry-run|--publish]"
TAG="v$VERSION"
BUILD_NUMBER=$(git rev-list --count HEAD)

# Full Xcode is needed for xcodebuild even when xcode-select points at the Command Line Tools (same as the Makefile).
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi

DERIVED=build/release-derived
OUT=build/release/$VERSION
STAGE=$OUT/stage
ZIP=$OUT/$APP-$VERSION.zip
DMG=$OUT/$APP-$VERSION.dmg
APPCAST=$OUT/appcast.xml
NOTES=$OUT/RELEASE_NOTES.md
CASK=$OUT/macdown2.rb
DL_URL=https://github.com/$REPO/releases/download/$TAG

if [ "$PUBLISH" = 1 ]; then
  [ -z "$(git status --porcelain)" ] || die "working tree is dirty; commit or stash first"
  [ -n "$(git branch -r --contains HEAD)" ] || die "HEAD is not pushed; push it so the tag has a commit to point at"
  command -v gh >/dev/null || die "gh is required for --publish"
fi

rm -rf "$OUT"; mkdir -p "$STAGE"

# ---- 1. Release build (version stamped via build settings; the checked-in project stays at its dev version).
#         -destination generic/platform=macOS is what makes it build every ARCHS entry: a concrete "My Mac"
#         destination builds only the host architecture. ----
step "Release build $VERSION (build $BUILD_NUMBER)"
xcodebuild -project MacDown2.xcodeproj -scheme MacDown2 -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build >"$OUT/xcodebuild.log" 2>&1 \
  || { tail -30 "$OUT/xcodebuild.log"; die "build failed (full log: $OUT/xcodebuild.log)"; }
ditto "$DERIVED/Build/Products/Release/$APP.app" "$STAGE/$APP.app"
APP_PATH=$STAGE/$APP.app

# ---- 1b. Universal binary: every Mach-O in the bundle (app, Quick Look appex, Sparkle framework / Autoupdate /
#          Updater.app / XPC services) must carry both arm64 and x86_64 (Intel Macs that run macOS 26 are supported).
step "Checking architectures (arm64 + x86_64)"
MACHO_COUNT=0
while IFS= read -r f; do
  [[ "$(file -b "$f")" == Mach-O* ]] || continue
  archs=" $(lipo -archs "$f") "
  [[ "$archs" == *" arm64 "* && "$archs" == *" x86_64 "* ]] || die "not universal (arm64 + x86_64): ${f#"$APP_PATH"/} ->$archs"
  MACHO_COUNT=$((MACHO_COUNT + 1)); echo "  ${archs# } ${f#"$APP_PATH"/}"
done < <(find "$APP_PATH" -type f | sort)
# Guard against the loop silently checking nothing: these must have been among the files seen.
[ -f "$APP_PATH/Contents/MacOS/$APP" ] && [ -d "$APP_PATH/Contents/PlugIns/MacDown2QuickLook.appex" ] \
  && [ -f "$APP_PATH/Contents/Frameworks/Sparkle.framework/Sparkle" ] || die "expected app / appex / Sparkle binaries missing"
# The command line tool (cask `binary` and the "Install Command Line Tool…" menu both point at it) must be there and universal;
# its web assets are the app's own bundle, reached through a symlink, so a missing link would only show up at run time.
CLI_TOOL=$APP_PATH/Contents/Helpers/macdown2
[ -x "$CLI_TOOL" ] || die "Contents/Helpers/macdown2 is missing or not executable"
CLI_ARCHS=" $(lipo -archs "$CLI_TOOL") "
[[ "$CLI_ARCHS" == *" arm64 "* && "$CLI_ARCHS" == *" x86_64 "* ]] || die "Contents/Helpers/macdown2 is not universal (arm64 + x86_64): ->$CLI_ARCHS"
[ -f "$APP_PATH/Contents/Helpers/WebAssets_WebAssets.bundle/Contents/Resources/Resources/render.bundle.js" ] || die "Contents/Helpers/WebAssets_WebAssets.bundle does not resolve to the app's web assets"
[ "$MACHO_COUNT" -ge 8 ] || die "only $MACHO_COUNT Mach-O files found; expected app, appex, CLI, Sparkle and its helpers"

# ---- 2. Ad-hoc sign, innermost first. No --deep: it would re-sign the Quick Look appex without its sandbox
#         entitlement (which pluginkit requires); --preserve-metadata keeps what the build put on each bundle.
step "Ad-hoc signing (inner to outer)"
sign() { codesign --force --sign - --preserve-metadata=entitlements,identifier,flags "$1"; }
SPARKLE=$APP_PATH/Contents/Frameworks/Sparkle.framework
if [ -d "$SPARKLE" ]; then
  while IFS= read -r nested; do sign "$nested"; done < <(find "$SPARKLE" -type d \( -name '*.xpc' -o -name '*.app' \) -prune | sort)
  while IFS= read -r nested; do sign "$nested"; done < <(find "$SPARKLE" -type f -name Autoupdate)
  sign "$SPARKLE"
fi
for appex in "$APP_PATH"/Contents/PlugIns/*.appex; do sign "$appex"; done
sign "$APP_PATH/Contents/Helpers/macdown2"
sign "$APP_PATH"

# ---- 3. Verify the signed bundle ----
step "Verifying signatures"
codesign --verify --deep --strict "$APP_PATH"
# Capture first: `cmd | grep -q` under pipefail fails spuriously when grep exits before cmd finishes writing.
INFO=$(codesign -dv "$APP_PATH" 2>&1)
[[ "$INFO" == *"Signature=adhoc"* ]] || die "app is not ad-hoc signed"
APPEX=$APP_PATH/Contents/PlugIns/MacDown2QuickLook.appex
[ -d "$APPEX" ] || die "Quick Look appex is not embedded"
codesign --verify --strict "$APPEX"
ENTS=$(codesign -d --entitlements - "$APPEX" 2>&1)
[[ "$ENTS" == *"com.apple.security.app-sandbox"* ]] || die "appex lost its sandbox entitlement"
codesign --verify --strict "$APP_PATH/Contents/Helpers/macdown2"
[ "$("$APP_PATH/Contents/Helpers/macdown2" --version)" = "macdown2 $VERSION" ] || die "macdown2 --version does not report $VERSION"
PLIST=$APP_PATH/Contents/Info.plist
[ "$(plutil -extract CFBundleShortVersionString raw "$PLIST")" = "$VERSION" ] || die "version not stamped into Info.plist"
ED_KEY=$(plutil -extract SUPublicEDKey raw "$PLIST" 2>/dev/null || true)
KEY_OK=0; [ "$(printf %s "$ED_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" = 32 ] && KEY_OK=1
[ "$KEY_OK" = 1 ] || echo "WARNING: SUPublicEDKey in Info.plist is still a placeholder; this build will not check for updates." >&2

# ---- 4. zip (Sparkle) and dmg (humans, Homebrew) ----
step "Packaging"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP"
DMG_SRC=$OUT/dmg-src; mkdir -p "$DMG_SRC"
ditto "$APP_PATH" "$DMG_SRC/$APP.app"; ln -s /Applications "$DMG_SRC/Applications"
hdiutil create -quiet -volname "$APP $VERSION" -srcfolder "$DMG_SRC" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$DMG_SRC"
( cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS )
DMG_SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

# ---- 5. Release notes draft ----
step "Release notes draft"
PREV=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
{
  echo "## MacDown2 $VERSION"
  echo
  # Hand-written notes in docs/release-notes/<version>.md win; otherwise the commit subjects since the last tag.
  if [ -f "docs/release-notes/$VERSION.md" ]; then cat "docs/release-notes/$VERSION.md"
  else git log -n 50 --no-merges --pretty='- %s' ${PREV:+"$PREV..HEAD"}; fi
  echo
  echo "Install: brew install --cask xuanji86/tap/macdown2, or download the dmg below. The app is not notarized, so a manual download needs the one-time \"Open Anyway\" step (see the README)."
  echo
  echo "Source code: https://github.com/$REPO/tree/$TAG (GPL-3.0)"
} > "$NOTES"

# ---- 6. Sparkle EdDSA signature + appcast ----
step "Sparkle signature and appcast"
SIGN_UPDATE=${SIGN_UPDATE:-$(find "$DERIVED/SourcePackages/artifacts/sparkle" -path '*old_dsa_scripts*' -prune -o -name sign_update -type f -print 2>/dev/null | head -1 || true)}
GENERATE_KEYS=${SIGN_UPDATE:+$(dirname "$SIGN_UPDATE")/generate_keys}
ED_SIG=""
if [ -x "${SIGN_UPDATE:-}" ]; then
  # sign_update reports errors on stdout, so keep both streams.
  if SIGN_OUT=$("$SIGN_UPDATE" "$ZIP" 2>&1); then
    ED_SIG=$(printf %s "$SIGN_OUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
  else
    printf %s "$SIGN_OUT" > "$OUT/sign_update.err"
  fi
fi
if [ -z "$ED_SIG" ]; then
  echo "WARNING: no Sparkle EdDSA signature: $(head -c 200 "$OUT/sign_update.err" 2>/dev/null || echo 'sign_update not found')" >&2
  echo "         Run Sparkle's generate_keys once, put the public key in App/Info.plist (SUPublicEDKey), then re-run." >&2
elif [ "$KEY_OK" = 1 ] && [ "$("$GENERATE_KEYS" -p 2>/dev/null)" != "$ED_KEY" ]; then
  die "keychain EdDSA key does not match SUPublicEDKey in Info.plist; every installed copy would reject this update"
fi

# Carry over earlier items: the latest release's appcast if publishing, else a previous local run's.
PREV_APPCAST=build/release/appcast.xml
if [ "$PUBLISH" = 1 ]; then
  rm -f "$OUT/appcast.prev.xml"
  gh release download --repo "$REPO" --pattern appcast.xml --output "$OUT/appcast.prev.xml" 2>/dev/null && PREV_APPCAST=$OUT/appcast.prev.xml || PREV_APPCAST=
fi
python3 Scripts/update-appcast.py ${PREV_APPCAST:+--existing "$PREV_APPCAST"} --out "$APPCAST" \
  --version "$VERSION" --build "$BUILD_NUMBER" --url "$DL_URL/$(basename "$ZIP")" \
  --length "$(stat -f %z "$ZIP")" --ed-signature "$ED_SIG" --min-system "$MIN_SYSTEM" --notes "$NOTES"
xmllint --noout "$APPCAST"
cp "$APPCAST" build/release/appcast.xml   # carried into the next local run

# ---- 7. Homebrew cask ----
step "Cask"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$DMG_SHA/" Distribution/homebrew/macdown2.rb.template > "$CASK"
ruby -c "$CASK" >/dev/null

echo
echo "Artifacts in $OUT:"
ls -1 "$OUT" | grep -v -E '^(stage|xcodebuild.log|sign_update.err|appcast.prev.xml)$' | sed 's/^/  /'

if [ "$PUBLISH" != 1 ]; then
  echo
  echo "Dry run: nothing was uploaded or pushed. Re-run with --publish to create the draft release."
  exit 0
fi

# ---- 8. Publish: draft GitHub Release (+ tap) ----
[ "$KEY_OK" = 1 ] || die "refusing to publish: SUPublicEDKey is a placeholder"
[ -n "$ED_SIG" ] || die "refusing to publish: appcast item has no EdDSA signature"
step "Creating draft release $TAG"
# Never --prerelease: releases/latest/download/appcast.xml skips prereleases, so the feed would stop moving.
gh release create "$TAG" --repo "$REPO" --draft --target "$(git rev-parse HEAD)" --title "$APP $VERSION" \
  --notes-file "$NOTES" "$DMG" "$ZIP" "$APPCAST" "$OUT/SHA256SUMS"
echo "Draft created. Review it, then publish it on GitHub: publishing makes it 'latest', which is what hands the update to existing installs."

if [ -n "${TAP_DIR:-}" ]; then
  step "Updating tap checkout $TAP_DIR"
  mkdir -p "$TAP_DIR/Casks"; cp "$CASK" "$TAP_DIR/Casks/macdown2.rb"
  git -C "$TAP_DIR" add Casks/macdown2.rb
  git -C "$TAP_DIR" commit -m "macdown2 $VERSION"
  echo "Tap commit made but NOT pushed. Push it after you have published the release (the dmg URL must exist first)."
else
  echo "Set TAP_DIR to a checkout of the tap to have the cask committed there, or copy $CASK to Casks/macdown2.rb."
fi
