//
//  Perf.swift
//  GamesRoom
//
//  V0.69 — lightweight performance instrumentation. os_signpost for
//  Instruments + DEBUG-only print lines for log-stream capture. Zero
//  release-build cost (prints compiled out, signposts are cheap).
//

import Foundation

enum Perf {
    /// Time a named async block. DEBUG print for log-stream capture.
    @discardableResult
    static func span<T: Sendable>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        #if DEBUG
        let start = CFAbsoluteTimeGetCurrent()
        #endif
        let result = try await body()
        #if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(String(format: "[GamesRoom] perf %@ %.0fms", "\(name)", ms))
        #endif
        return result
    }

    /// Event marker (no duration).
    static func event(_ name: String) {
        #if DEBUG
        print("[GamesRoom] perf \(name)")
        #endif
    }
}
