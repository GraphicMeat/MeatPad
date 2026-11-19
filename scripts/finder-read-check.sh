#!/usr/bin/env bash
# Release-config proof that MeatPadFinder.appex reads the app's `finder.menu` default through
# its real entitlement (shared-preference.read-only) and not through the
# files.absolute-path.read-only ["/"] exception Xcode injects into build-for-testing products.
# Run inside a mini job (cwd = clone root):
#   ~/.claude/bin/testq ~/.claude/bin/minijob bash -c 'TESTQ_SKIP=1 scripts/finder-read-check.sh'
# Builds Release (no test action), refuses an appex carrying absolute-path, seeds a value of a
# known length, enables the extension and waits for its "finder.menu read: <length> chars"
# line. Then restores the default and the extension's registration exactly as found.
set -uo pipefail

EXT_ID=com.thecoldzero.MeatPad.FinderSync
APP_ID=com.thecoldzero.MeatPad
DD=DerivedData
APP="$DD/Build/Products/Release/MeatPad.app"
APPEX="$APP/Contents/PlugIns/MeatPadFinder.appex"
mkdir -p build

section() { printf '\n===== %s =====\n' "$*"; }

section "build (Release)"
xcodegen generate >/dev/null || { echo "xcodegen failed"; exit 1; }
xcodebuild -skipPackagePluginValidation -project MeatPad.xcodeproj -scheme MeatPad \
    -configuration Release -destination "platform=macOS,arch=arm64" -derivedDataPath "$DD" build \
    > build/release.log 2>&1
BUILD=$?
grep -E "error:|BUILD (SUCCEEDED|FAILED)" build/release.log | grep -v "^ *-" | tail -20
[ $BUILD -eq 0 ] || { echo "build failed ($BUILD)"; tail -60 build/release.log; exit $BUILD; }

section "appex entitlements"
[ -d "$APPEX" ] || { echo "no appex at $APPEX"; exit 1; }
ENTS=$(codesign -d --entitlements - --xml "$APPEX" 2>/dev/null | plutil -p - 2>&1)
echo "$ENTS"
codesign -dvv "$APPEX" 2>&1 | grep -E "Identifier|Signature|flags|TeamIdentifier"
if echo "$ENTS" | grep -q "absolute-path"; then
    echo "FAIL: the Release appex carries an absolute-path exception, so it proves nothing"
    exit 4
fi
echo "$ENTS" | grep -q "shared-preference.read-only" || { echo "FAIL: no shared-preference.read-only"; exit 4; }

section "prior state"
PRIOR_MENU=$(defaults read "$APP_ID" finder.menu 2>/dev/null); PRIOR_RC=$?
echo "finder.menu before: rc=$PRIOR_RC value=${PRIOR_MENU:-<none>}"
echo "pluginkit before:"; pluginkit -m -v -i "$EXT_ID" 2>&1; echo "(end)"

cleanup() {
    section "cleanup"
    pluginkit -e ignore -i "$EXT_ID" 2>&1
    pluginkit -r "$APPEX" 2>&1
    if [ $PRIOR_RC -eq 0 ]; then
        defaults write "$APP_ID" finder.menu -string "$PRIOR_MENU"
    else
        defaults delete "$APP_ID" finder.menu 2>&1
    fi
    echo "pluginkit after cleanup:"; pluginkit -m -v -i "$EXT_ID" 2>&1; echo "(end)"
    echo "finder.menu after cleanup: $(defaults read "$APP_ID" finder.menu 2>&1)"
}
trap cleanup EXIT

section "seed + enable"
# ASCII only, so bash's ${#} and Swift's String.count agree; the pad makes the length unusual.
SEED='{"groupInSubmenu":false,"readCheck":"release-config-proof-xyzzy-7"}'
LEN=${#SEED}
echo "seed length: $LEN"
START=$(date '+%Y-%m-%d %H:%M:%S')
defaults write "$APP_ID" finder.menu -string "$SEED"
pluginkit -a "$APPEX"; echo "pluginkit -a rc=$?"
pluginkit -e use -i "$EXT_ID"; echo "pluginkit -e use rc=$?"
sleep 2
pluginkit -m -v -i "$EXT_ID" 2>&1

section "wait for the read"
FOUND=""
for _ in $(seq 1 15); do
    sleep 2
    FOUND=$(log show --start "$START" --style compact \
        --predicate 'subsystem == "com.thecoldzero.MeatPad.FinderSync"' 2>/dev/null \
        | grep -E "finder.menu read: $LEN chars" | tail -1)
    [ -n "$FOUND" ] && break
done
echo "extension process: $(pgrep -fl 'MeatPadFinder.appex/Contents/MacOS' || echo '(none)')"
echo "extension log:"
log show --start "$START" --style compact \
    --predicate 'subsystem == "com.thecoldzero.MeatPad.FinderSync"' 2>&1 | grep -v "^Timestamp" | tail -20
echo "sandbox denials mentioning the extension:"
log show --start "$START" --style compact \
    --predicate '(process == "kernel" OR process == "sandboxd") AND eventMessage CONTAINS[c] "MeatPadFinder"' 2>&1 \
    | grep -v "^Timestamp" | tail -10

if [ -n "$FOUND" ]; then
    echo "PASS: $FOUND"
    exit 0
fi
echo "FAIL: no 'finder.menu read: $LEN chars' line within 30 s"
exit 5
