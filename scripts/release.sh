#!/usr/bin/env bash
#
# scripts/release.sh <version> [--dry-run] [--publish] [--notes-file <path>]
#
# Builds, signs, notarizes, packages, and (optionally) publishes a MeatPad
# release. Run from the repo root.
#
# ONE-TIME SETUP (do this once per machine, before phase 3 ever runs):
#
#   xcrun notarytool store-credentials meatpad-notary \
#     --apple-id <your-apple-id-email> \
#     --team-id YXDJG24NWG \
#     --password <app-specific-password>
#
#   (App-specific password from https://appleid.apple.com — Sign-In and
#   Security > App-Specific Passwords. Team ID is MB Modernios Aplikacijos.)
#
# Phases:
#   1. Preflight  - sanity checks, no side effects.
#   2. Build      - xcodebuild archive + export (Developer ID signed .app).
#   3. Notarize   - notarytool submit --wait + stapler staple.
#   4. DMG        - staged /Applications-symlink DMG, stapled.
#   5. Appcast    - sign_update + hand-built appcast.xml.
#   6. Publish    - gh release create (only with --publish).
#
# --dry-run runs phases 1-2 only, then verifies the exported .app and stops
# before anything that signs with notarytool, uploads, or publishes.
#
# --publish is required to run phase 6. Without it, phases 1-5 run and the
# script prints the exact `gh release create` command to run by hand.

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

VERSION=""
DRY_RUN=false
PUBLISH=false
NOTES_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --publish) PUBLISH=true; shift ;;
    --notes-file) NOTES_FILE="$2"; shift 2 ;;
    -*) echo "error: unknown flag $1" >&2; exit 1 ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "error: unexpected extra argument $1" >&2; exit 1
      fi
      VERSION="$1"; shift ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "usage: scripts/release.sh <version> [--dry-run] [--publish] [--notes-file <path>]" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TEAM_ID="YXDJG24NWG"
SIGN_IDENTITY="Developer ID Application: MB Modernios Aplikacijos (${TEAM_ID})"
NOTARY_PROFILE="meatpad-notary"
BUNDLE_ID="com.thecoldzero.MeatPad"
GH_REPO="thecoldzero/MeatPad"
SCHEME="MeatPad"
PROJECT="MeatPad.xcodeproj"

RELEASE_DIR="$ROOT_DIR/release/$VERSION"
ARCHIVE_PATH="$RELEASE_DIR/MeatPad.xcarchive"
EXPORT_DIR="$RELEASE_DIR/export"
APP_PATH="$EXPORT_DIR/MeatPad.app"
DMG_NAME="MeatPad-${VERSION}.dmg"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
APPCAST_PATH="$RELEASE_DIR/appcast.xml"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
fail() { printf '\n\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

mkdir -p "$RELEASE_DIR"

# ---------------------------------------------------------------------------
# Phase 1: Preflight
# ---------------------------------------------------------------------------

log "Phase 1: Preflight"

# Clean tree check — allow the known untracked scratch paths, fail on
# anything else (modified/staged tracked files, or unexpected untracked
# files).
dirty="$(git status --porcelain \
  | grep -v -E '^\?\? (App/Resources/|tmp/|release/|docs/)' || true)"
if [[ -n "$dirty" ]]; then
  echo "$dirty" >&2
  fail "working tree is not clean (see above). Commit, stash, or ignore before releasing."
fi

# Version arg must match project.yml. We do NOT bump it here — a version
# bump is a manual commit, by design.
PROJECT_YML_VERSION="$(grep -m1 'MARKETING_VERSION:' project.yml | sed -E 's/.*MARKETING_VERSION: *"?([0-9A-Za-z.]+)"?.*/\1/')"
if [[ "$PROJECT_YML_VERSION" != "$VERSION" ]]; then
  fail "version mismatch: project.yml has MARKETING_VERSION=$PROJECT_YML_VERSION, script was called with $VERSION. Bump project.yml first (manual commit) and re-run."
fi
log "version $VERSION matches project.yml"

command -v xcodegen >/dev/null || fail "xcodegen not found in PATH"
xcodegen generate
log "xcodegen generate done"

if [[ "$DRY_RUN" == false ]]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    fail "notarytool keychain profile '$NOTARY_PROFILE' not found. One-time setup:
  xcrun notarytool store-credentials $NOTARY_PROFILE \\
    --apple-id <your-apple-id-email> \\
    --team-id $TEAM_ID \\
    --password <app-specific-password>"
  fi
  log "notarytool profile '$NOTARY_PROFILE' found"

  if ! gh auth status >/dev/null 2>&1; then
    fail "gh is not authenticated. Run: gh auth login"
  fi
  log "gh auth OK"
else
  log "dry-run: skipping notarytool profile check and gh auth check"
fi

# Locate the Sparkle command-line tools resolved by SwiftPM. They live under
# a hashed DerivedData dir, so glob for them rather than hardcoding the hash.
find_sparkle_tool() {
  local tool_name="$1"
  local hit
  hit="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -type f -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/${tool_name}" \
    -perm -u+x 2>/dev/null | head -n1 || true)"
  if [[ -z "$hit" ]]; then
    fail "could not locate Sparkle tool '$tool_name' under ~/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/bin/. Build the app once in Xcode (or run xcodebuild -resolvePackageDependencies) so SwiftPM resolves the Sparkle artifact, then re-run."
  fi
  echo "$hit"
}

SIGN_UPDATE="$(find_sparkle_tool sign_update)"
GENERATE_APPCAST="$(find_sparkle_tool generate_appcast)"
log "sign_update:      $SIGN_UPDATE"
log "generate_appcast: $GENERATE_APPCAST"

# ---------------------------------------------------------------------------
# Phase 2: Build
# ---------------------------------------------------------------------------

log "Phase 2: Build (archive + export)"

EXPORT_OPTIONS_PLIST="$RELEASE_DIR/exportOptions.plist"
cat > "$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
	<key>hardenedRuntime</key>
	<true/>
</dict>
</plist>
PLIST

rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"

xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  archive -archivePath "$ARCHIVE_PATH"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

[[ -d "$APP_PATH" ]] || fail "export did not produce $APP_PATH"
log "exported: $APP_PATH"

# xcodebuild's workspace-level SwiftPM resolution can incidentally rewrite
# MeatPadKit/Package.resolved (pulling in the app's Sparkle dependency even
# though MeatPadKit itself doesn't depend on it). That's not a real lockfile
# change, so discard it rather than leaving the tree dirty for future runs.
if ! git -C "$ROOT_DIR" diff --quiet -- MeatPadKit/Package.resolved 2>/dev/null; then
  git -C "$ROOT_DIR" checkout -- MeatPadKit/Package.resolved
  log "reverted incidental MeatPadKit/Package.resolved churn from package resolution"
fi

codesign -dv --verbose=2 "$APP_PATH" 2>&1 | tee "$RELEASE_DIR/codesign-check.txt"
if ! grep -q "Authority=Developer ID Application: MB Modernios Aplikacijos" "$RELEASE_DIR/codesign-check.txt"; then
  fail "codesign check failed: $APP_PATH is not signed with '$SIGN_IDENTITY'"
fi
log "codesign check OK: signed with Developer ID"

if [[ "$DRY_RUN" == true ]]; then
  log "dry-run: stopping after phase 2 (build). App at $APP_PATH is built and Developer ID signed but NOT notarized."
  exit 0
fi

# ---------------------------------------------------------------------------
# Phase 3: Notarize
# ---------------------------------------------------------------------------

log "Phase 3: Notarize"

NOTARIZE_ZIP="$RELEASE_DIR/MeatPad-notarize.zip"
rm -f "$NOTARIZE_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

xcrun stapler staple "$APP_PATH"
log "stapled: $APP_PATH"

# ---------------------------------------------------------------------------
# Phase 4: DMG
# ---------------------------------------------------------------------------

log "Phase 4: DMG"

DMG_STAGING="$RELEASE_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
ditto "$APP_PATH" "$DMG_STAGING/MeatPad.app"
ln -s /Applications "$DMG_STAGING/Applications"

rm -f "$DMG_PATH"
hdiutil create -volname "MeatPad $VERSION" -srcfolder "$DMG_STAGING" -format UDZO "$DMG_PATH"

xcrun stapler staple "$DMG_PATH"
spctl -a -vv --type install "$DMG_PATH"
log "DMG built, stapled, and gatekeeper-approved: $DMG_PATH"

# ---------------------------------------------------------------------------
# Phase 5: Appcast
# ---------------------------------------------------------------------------

log "Phase 5: Appcast"

# We hand-build the appcast item rather than running generate_appcast over a
# releases/ directory: generate_appcast is built for a maintained archive of
# every past DMG (it diffs them to emit delta updates and can reach out to
# the existing SUFeedURL to merge history). For the very first release there
# is no history to diff and no published feed to merge from, so pointing it
# at a one-DMG directory buys nothing but an extra moving part. A hand-built
# single-<item> feed is deterministic and dependency-free.
#
# Once there's real release history, switch to generate_appcast over a
# maintained releases/ dir (keep every past .dmg there) so it can compute
# deltas automatically; hand-editing multi-item appcasts by hand doesn't
# scale.

SIGNATURE_OUTPUT="$("$SIGN_UPDATE" "$DMG_PATH")"
log "sign_update output: $SIGNATURE_OUTPUT"

# sign_update prints: sparkle:edSignature="..." length="12345"
ED_SIGNATURE="$(echo "$SIGNATURE_OUTPUT" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')"
DMG_LENGTH="$(echo "$SIGNATURE_OUTPUT" | sed -nE 's/.*length="([0-9]+)".*/\1/p')"
[[ -n "$ED_SIGNATURE" ]] || fail "could not parse edSignature from sign_update output: $SIGNATURE_OUTPUT"
[[ -n "$DMG_LENGTH" ]] || fail "could not parse length from sign_update output: $SIGNATURE_OUTPUT"

PUB_DATE="$(LC_ALL=en_US.UTF-8 date -u +"%a, %d %b %Y %H:%M:%S +0000")"

cat > "$APPCAST_PATH" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MeatPad</title>
    <link>https://github.com/${GH_REPO}/releases/latest/download/appcast.xml</link>
    <description>MeatPad release notes</description>
    <language>en</language>
    <item>
      <title>MeatPad ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/${GH_REPO}/releases/download/v${VERSION}/${DMG_NAME}"
        length="${DMG_LENGTH}"
        type="application/octet-stream"
        sparkle:edSignature="${ED_SIGNATURE}" />
    </item>
  </channel>
</rss>
XML

log "wrote appcast: $APPCAST_PATH"

# ---------------------------------------------------------------------------
# Phase 6: Publish
# ---------------------------------------------------------------------------

if [[ -z "$NOTES_FILE" ]]; then
  NOTES_FILE="$RELEASE_DIR/notes.md"
  if [[ ! -f "$NOTES_FILE" ]]; then
    echo "MeatPad ${VERSION}" > "$NOTES_FILE"
  fi
fi

PUBLISH_CMD=(gh release create "v${VERSION}" "$DMG_PATH" "$APPCAST_PATH" \
  --repo "$GH_REPO" --title "MeatPad ${VERSION}" --notes-file "$NOTES_FILE")

if [[ "$PUBLISH" == true ]]; then
  log "Phase 6: Publish"
  "${PUBLISH_CMD[@]}"
  log "published v${VERSION}"
else
  log "Phase 6: skipped (no --publish). Run this by hand when ready:"
  printf '  %q ' "${PUBLISH_CMD[@]}"
  printf '\n'
fi

log "release $VERSION artifacts in $RELEASE_DIR"
