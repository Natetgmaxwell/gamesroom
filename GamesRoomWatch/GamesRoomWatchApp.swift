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
