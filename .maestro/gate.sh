#!/usr/bin/env bash
# Games Room full gate. Run from anywhere inside the repo on the Mac Studio.
# Prints only the lines that matter. Exit 0 = both test paths green.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
export PATH=/opt/homebrew/bin:$PATH
# Xcode.app's CoreSimulator is older than the installed one; Xcode-beta owns the sims.
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
RB=/tmp/gr-gate.xcresult
rc=0

echo "GATE unit: running build-and-run-tests.sh"
unit=$(bash build-and-run-tests.sh 2>&1)
echo "$unit" | grep -E "cases:|parse-check|error:" | tail -6
echo "$unit" | grep -qE "[0-9]+ cases: [0-9]+ passed, 0 failed" || { echo "GATE unit: FAIL"; rc=1; }

echo "GATE sweep: xcodegen + ScreenshotSweepTests"
/opt/homebrew/bin/xcodegen generate --quiet >/dev/null 2>&1 || { echo "GATE xcodegen: FAIL"; exit 1; }
rm -rf "$RB"
sweep=$(xcodebuild test -project GamesRoom.xcodeproj -scheme GamesRoom \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:GamesRoomUITests/ScreenshotSweepTests \
  -resultBundlePath "$RB" 2>&1)
echo "$sweep" | grep -E "error:|Executed [0-9]+ test|TEST (SUCCEEDED|FAILED)" | tail -6
echo "$sweep" | grep -q "TEST SUCCEEDED" || { echo "GATE sweep: FAIL"; rc=1; }

if [ $rc -eq 0 ]; then echo "GATE: PASS"; else echo "GATE: FAIL"; fi
exit $rc
