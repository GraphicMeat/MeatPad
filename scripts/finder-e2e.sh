#!/usr/bin/env bash
# Finder Sync extension end to end, on the mac mini (run inside a minijob, cwd = clone root):
#   ~/.claude/bin/testq ~/.claude/bin/minijob --artifacts <dir> bash -c 'TESTQ_SKIP=1 scripts/finder-e2e.sh'
# Builds, registers + enables MeatPadFinder.appex, seeds `finder.menu`, runs
# FinderContextMenuUITests, saves screenshots to .artifacts/, prints the extension's logs,
# then unregisters the extension and removes the seed so the mini is left as found.
set -uo pipefail

EXT_ID=com.thecoldzero.MeatPad.FinderSync
APP_ID=com.thecoldzero.MeatPad
DD=DerivedData
APP="$DD/Build/Products/Debug/MeatPad.app"
APPEX="$APP/Contents/PlugIns/MeatPadFinder.appex"
RESULT=build/finder-e2e.xcresult
mkdir -p .artifacts build
START=$(date '+%Y-%m-%d %H:%M:%S')

section() { printf '\n===== %s =====\n' "$*"; }

section "build"
xcodegen generate >/dev/null || { echo "xcodegen failed"; exit 1; }
xcodebuild -skipPackagePluginValidation -project MeatPad.xcodeproj -scheme MeatPad \
    -destination "platform=macOS,arch=arm64" -derivedDataPath "$DD" build-for-testing \
    > build/build.log 2>&1
BUILD=$?
grep -E "error:|BUILD (SUCCEEDED|FAILED)|TEST BUILD (SUCCEEDED|FAILED)" build/build.log | grep -v "^ *-" | tail -40
[ $BUILD -eq 0 ] || { echo "build failed ($BUILD)"; tail -60 build/build.log; exit $BUILD; }

section "embedded appex"
ls -la "$APP/Contents/PlugIns" 2>&1
plutil -p "$APPEX/Contents/Info.plist" 2>&1 | grep -E "CFBundleIdentifier|NSExtension|Principal|PointIdentifier"
codesign -dvv "$APPEX" 2>&1 | grep -E "Identifier|Signature|flags|TeamIdentifier"
codesign -d --entitlements - --xml "$APPEX" 2>/dev/null | plutil -p - 2>&1

section "prior state"
echo "pluginkit before:"; pluginkit -m -v -i "$EXT_ID" 2>&1
PRIOR_MENU=$(defaults read "$APP_ID" finder.menu 2>/dev/null); PRIOR_RC=$?
echo "finder.menu before: rc=$PRIOR_RC value=${PRIOR_MENU:-<none>}"
echo "pluginkit -A -D before:"; pluginkit -m -A -D -v -i "$EXT_ID" 2>&1; echo "(end)"
ls -d "$HOME/Library/Containers/$EXT_ID" 2>&1

cleanup() {
    section "cleanup"
    [ -n "${SAMPLER:-}" ] && kill "$SAMPLER" 2>/dev/null
    pluginkit -e ignore -i "$EXT_ID" 2>&1
    pluginkit -r "$APPEX" 2>&1
    if [ $PRIOR_RC -eq 0 ]; then
        defaults write "$APP_ID" finder.menu -string "$PRIOR_MENU"
    else
        defaults delete "$APP_ID" finder.menu 2>&1
    fi
    echo "pluginkit after cleanup:"; pluginkit -m -v -i "$EXT_ID" 2>&1; echo "(end)"
    echo "finder.menu after cleanup: $(defaults read "$APP_ID" finder.menu 2>&1)"
    echo "pluginkit -A -D after cleanup:"; pluginkit -m -A -D -v -i "$EXT_ID" 2>&1; echo "(end)"
    ls -d "$HOME/Library/Containers/$EXT_ID" 2>&1
}
trap cleanup EXIT

section "register + enable"
# The JSON is text, not a plist dictionary: -string keeps it a string.
defaults write "$APP_ID" finder.menu -string '{}'
pluginkit -a "$APPEX"; echo "pluginkit -a rc=$?"
pluginkit -e use -i "$EXT_ID"; echo "pluginkit -e use rc=$?"
sleep 2
pluginkit -m -v -i "$EXT_ID" 2>&1

# Sample the extension process every second: when (if) Finder loads it.
( while :; do printf '%s ' "$(date +%T)"; pgrep -fl 'MeatPadFinder.appex/Contents/MacOS' | tr '\n' ';'; echo; sleep 1; done ) \
    > .artifacts/pgrep.log 2>&1 &
SAMPLER=$!

section "test"
rm -rf "$RESULT"
export TEST_RUNNER_MEATPAD_FINDER_E2E=1
xcodebuild -skipPackagePluginValidation -project MeatPad.xcodeproj -scheme MeatPad \
    -destination "platform=macOS,arch=arm64" -derivedDataPath "$DD" \
    -resultBundlePath "$RESULT" \
    -only-testing:MeatPadUITests/FinderContextMenuUITests test-without-building \
    > build/test.log 2>&1
TEST=$?
grep -E "Test Case|Executed|FINDER_E2E|error:|Testing failed|TEST (EXECUTE )?(SUCCEEDED|FAILED)|XCTAssert|Skipped" build/test.log | tail -60
echo "test rc=$TEST"
# A skipped or empty run says TEST SUCCEEDED too: only an executed, unskipped pass counts.
SUMMARY=$(grep -E "Executed [0-9]+ test" build/test.log | tail -1)
echo "summary: ${SUMMARY:-<none>}"
if [ $TEST -eq 0 ] && ! echo "$SUMMARY" | grep -qE "Executed [1-9][0-9]* tests?, with 0 failures"; then
    echo "no executed pass -> failing"; TEST=3
fi
if echo "$SUMMARY" | grep -q "skipped"; then echo "skipped test(s) -> failing"; TEST=3; fi

section "extension process"
pgrep -fl "MeatPadFinder.appex/Contents/MacOS" || echo "(no MeatPadFinder process)"
echo "first sample with the process:"; grep -m1 MacOS .artifacts/pgrep.log || echo "(never seen)"
echo "first/last sample:"; head -1 .artifacts/pgrep.log; tail -1 .artifacts/pgrep.log
pluginkit -m -v -i "$EXT_ID" 2>&1

section "attachments"
xcrun xcresulttool export attachments --path "$RESULT" --output-path .artifacts/attachments 2>&1 | tail -5
ls -la .artifacts/attachments 2>&1
screencapture -x .artifacts/desktop.png 2>&1 || true

section "log: extension subsystem"
log show --start "$START" --style compact \
    --predicate 'subsystem == "com.thecoldzero.MeatPad.FinderSync"' 2>&1 | tail -60
section "log: extension process (non-subsystem) + system daemons mentioning it"
log show --start "$START" --style compact \
    --predicate '(process == "MeatPadFinder" AND NOT subsystem == "com.thecoldzero.MeatPad.FinderSync") OR (process IN {"pkd", "runningboardd", "launchd", "amfid", "syspolicyd", "secinitd", "containermanagerd", "kernel", "sandboxd", "Finder", "cfprefsd", "extensionkitservice"} AND (eventMessage CONTAINS[c] "MeatPadFinder" OR eventMessage CONTAINS[c] "MeatPad.FinderSync"))' \
    2>&1 | grep -v 'log show' | tail -100

exit $TEST
