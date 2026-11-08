#!/usr/bin/env bash
# Lane fast gate (TARS). Unit runner + SwiftUI parse check; --compile adds a simulator-less xcodebuild build.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
export PATH=/opt/homebrew/bin:$PATH
find . -name '* [0-9]*.swift' -not -path './.archive/*' -delete 2>/dev/null
u=$(bash build-and-run-tests.sh 2>&1)
echo "$u" | grep -E "cases:|parse-check|error:" | tail -8
echo "$u" | grep -qE "[0-9]+ cases: [0-9]+ passed, 0 failed" || { echo "FASTGATE: FAIL (unit)"; exit 1; }
if [ "${1:-}" = "--compile" ]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  /opt/homebrew/bin/xcodegen generate --quiet >/dev/null 2>&1 || { echo "FASTGATE: FAIL (xcodegen)"; exit 1; }
  lane=$(git rev-parse --abbrev-ref HEAD | tr '/' '-')
  b=$(xcodebuild build -project GamesRoom.xcodeproj -scheme GamesRoom -destination 'generic/platform=iOS Simulator' -derivedDataPath "/tmp/dd-$lane" CODE_SIGNING_ALLOWED=NO 2>&1)
  echo "$b" | grep -E " error:" | head -15
  git checkout -- GamesRoom.xcodeproj/project.pbxproj 2>/dev/null
  echo "$b" | grep -q "BUILD SUCCEEDED" || { echo "FASTGATE: FAIL (compile)"; exit 1; }
fi
echo "FASTGATE: PASS"
