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
           GamesRoom/Packs/*.swift)

echo "Compiling ${BIN} against $SDK..."
swiftc \
  -target "$TARGET" \
  -sdk "$SDK" \
  -o "$BIN" \
  "${SRC_FILES[@]}"

echo ""
echo "Running tests..."
./"$BIN"