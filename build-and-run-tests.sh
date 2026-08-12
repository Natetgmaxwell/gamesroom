#!/usr/bin/env bash
#
# build-and-run-tests.sh
#
# Compiles the Foundation-only slice of games-room (Models/ +
# Packs/) together with main.swift into a single test binary and
# runs it. Designed for build hosts without Xcode.app (where
# `xcodebuild test` is unreachable).
#
# Run from the games-room repo root:
#   ./build-and-run-tests.sh
#
# Exit code matches the test binary: 0 on all-pass, 1 on any
# failure.
#

set -euo pipefail

SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macosx14.0"
BIN="games-room-tests"
SRC_FILES=(main.swift
           GamesRoom/Models/*.swift
           GamesRoom/Packs/*.swift
           GamesRoom/Services/StorageKeys.swift
           GamesRoom/Services/RoomStoreProtocol.swift
           GamesRoom/Services/InMemoryRoomStore.swift
           GamesRoom/Services/MascotEngine.swift)

echo "Compiling ${BIN} against $SDK..."
swiftc \
  -target "$TARGET" \
  -sdk "$SDK" \
  -o "$BIN" \
  "${SRC_FILES[@]}"

echo ""
echo "Running tests..."
./"$BIN"

echo ""
echo "Parse-checking SwiftUI + Services..."
# B1.2: catch SwiftUI body-shape errors that the Foundation runner
# can't see (it only compiles Models/ + Packs/). On macOS-SDK hosts
# this is a best-effort gate; the real gate is `xcodebuild` on a Mac
# with Xcode.
set +e
./scripts/parse-check-swiftui.sh
PARSE_RC=$?
set -e
if [ "$PARSE_RC" -ne 0 ]; then
    echo "parse-check-swiftui.sh failed (rc=$PARSE_RC)" >&2
    exit 1
fi