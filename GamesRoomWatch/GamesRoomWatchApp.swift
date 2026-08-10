//
//  GamesRoomWatchApp.swift
//  GamesRoomWatch
//
//  Track F-MVP-12 (W2.3) — Watch complication + glance.
//
//  The Watch app reads the same App Group score snapshot the
//  widget reads (ScoreSnapshotStore). The complication shows the
//  room's current standings; the app body is a minimal list.
//
//  NOTE: this target cannot be built on the CommandLineTools host
//  (WatchKit needs the iOS/watchOS SDK). Verified structurally by
//  scripts/verify-xcode-project.py; requires an Xcode host for a
//  real build + device render check.
//

import SwiftUI
import WatchKit

/// The score snapshot the app writes and the watch reads. Mirrors
/// GamesRoom/Models/ScoreSnapshot.swift (the watch compiles its
/// own copy — no shared framework). Keep in sync.
struct ScoreSnapshot: Codable {
    var roomName: String
    var leaderboardLine: String
    var isLive: Bool
    var updatedAt: Date

    static let suiteName = "group.com.gamesroom.app"
    private static let key = "scoreSnapshot"

    static func load() -> ScoreSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ScoreSnapshot.self, from: data)
    }
}

@main
struct GamesRoomWatchApp: App {
    var body: some Scene {
        WindowGroup {
            ScoreWatchView()
        }
    }
}

struct ScoreWatchView: View {
    @State private var snapshot: ScoreSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot?.roomName ?? "Games Room")
                .font(.headline)
            if let line = snapshot?.leaderboardLine, !line.isEmpty {
                Text(line)
                    .font(.caption)
                    .lineLimit(4)
            } else {
                Text("No scores yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task {
            snapshot = ScoreSnapshot.load()
        }
    }
}
