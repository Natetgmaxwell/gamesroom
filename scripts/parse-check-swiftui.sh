#!/usr/bin/env bash
#
# scripts/parse-check-swiftui.sh
#
# SwiftUI body-shape errors in GamesRoom/Views/ and GamesRoom/Services/
# are invisible to the Foundation-only test runner (it only compiles
# Models/ + Packs/). This script runs `swiftc -parse` over every
# Swift file in those two trees so the CommandLineTools host can
# catch the obvious shape errors without a full Xcode.app build.
#
# SDK selection:
#   - iOS SDK preferred (this is an iOS 26 app).
#   - macOS SDK fallback when iOS SDK is missing (e.g. CommandLineTools
#     only). The fallback runs as a "best-effort" gate; SwiftUI
#     types like `NavigationStack` will parse either way, but any
#     iOS-only `@available` annotation will fail-soft with a banner.
#   - Exit code 0 = clean parse, 1 = one or more parse errors.
#
# Usage: ./scripts/parse-check-swiftui.sh
#

# macOS /bin/sh is bash 3.2 — no `mapfile`, no `${arr[@]}` on empty
# arrays. Run this with bash explicitly.
if [ -z "${BASH_VERSION:-}" ]; then
    exec /usr/bin/env bash "$0" "$@"
fi

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TARGET="arm64-apple-macosx14.0"

if xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
    SDK_LABEL="iphoneos"
else
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
    SDK_LABEL="macosx (best-effort: iOS SDK not installed on this host)"
fi

SWIFT_FILES=""
while IFS= read -r f; do
    SWIFT_FILES="$SWIFT_FILES $f"
done < <(find GamesRoom/Views GamesRoom/Services -type f -name '*.swift' | sort)

# shellcheck disable=SC2086
set -- $SWIFT_FILES

if [ "$#" -eq 0 ]; then
    echo "parse-check-swiftui: no SwiftUI / Services files found" >&2
    exit 1
fi

echo "parse-check-swiftui: scanning $# file(s) with $SDK_LABEL SDK"

PASS=0
FAIL=0

set +e
for f in "$@"; do
    ERR_FILE="$(mktemp -t parse-err)"
    if swiftc -target "$TARGET" -sdk "$SDK" -parse "$f" 2>"$ERR_FILE" >/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "----- parse error in $f -----" >&2
        cat "$ERR_FILE" >&2
    fi
    rm -f "$ERR_FILE"
done
set -e

echo "parse-check-swiftui: pass=$PASS fail=$FAIL"

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi

exit 0