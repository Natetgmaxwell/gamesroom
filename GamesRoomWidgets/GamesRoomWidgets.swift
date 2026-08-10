//
//  GamesRoomWidgets.swift
//  GamesRoomWidgets
//
//  Track F-MVP-12 (W2.3) — Glance widget + Live Activity.
//
//  The Glance shows the room's live score with a 1-minute refresh
//  budget (vision constraint). Data comes from the App Group
//  UserDefaults suite the app writes on every room refresh
//  (ScoreSnapshotStore). The Live Activity surfaces the score
//  OUTSIDE play only — the app ends it when play starts and
//  starts it for pre-play briefing / post-settle ceremonial
//  (vision: "No Live Activity during play").
//
//  NOTE: this target cannot be built on the CommandLineTools host
//  (WidgetKit/ActivityKit need the iOS SDK). Verified structurally
//  by scripts/verify-xcode-project.py; requires an Xcode host for
//  a real build + device render check.
//

import WidgetKit
import SwiftUI
import ActivityKit

// MARK: - Shared snapshot (App Group)

/// The score snapshot the app writes and the widget reads. The
/// widget is a separate process; the App Group UserDefaults suite
/// is the shared channel. Mirrors GamesRoom/Models/ScoreSnapshot.swift
/// (the app target compiles its own copy — no shared framework).
struct ScoreSnapshot: Codable {
    var roomName: String
    var leaderboardLine: String
    var isLive: Bool
    var updatedAt: Date

    static let suiteName = "group.com.gamesroom.app"

    static func load() -> ScoreSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: "scoreSnapshot") else { return nil }
        return try? JSONDecoder().decode(ScoreSnapshot.self, from: data)
    }
}

// MARK: - Glance widget

struct ScoreGlanceEntry: TimelineEntry {
    let date: Date
    let snapshot: ScoreSnapshot?
}

struct ScoreGlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScoreGlanceEntry {
        ScoreGlanceEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ScoreGlanceEntry) -> Void) {
        completion(ScoreGlanceEntry(date: Date(), snapshot: ScoreSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScoreGlanceEntry>) -> Void) {
        let entry = ScoreGlanceEntry(date: Date(), snapshot: ScoreSnapshot.load())
        // 1-minute refresh budget per vision constraint.
        let next = Calendar.current.date(byAdding: .minute, value: 1, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct ScoreGlanceView: View {
    var entry: ScoreGlanceEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.snapshot?.roomName ?? "Games Room")
                .font(.headline)
                .foregroundStyle(.primary)
            if let line = entry.snapshot?.leaderboardLine, !line.isEmpty {
                Text(line)
                    .font(.caption)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
            } else {
                Text("No scores yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let updated = entry.snapshot?.updatedAt {
                Text(updated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct ScoreGlanceWidget: Widget {
    static let kind = "ScoreGlance"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: ScoreGlanceProvider()) { entry in
            ScoreGlanceView(entry: entry)
        }
        .configurationDisplayName("Live score")
        .description("The room's current standings at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Live Activity (score surface, NOT during play)

struct ScoreActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var leaderboardLine: String
    }

    var roomName: String
}

struct ScoreLiveActivityView: View {
    let context: ActivityViewContext<ScoreActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(context.attributes.roomName)
                .font(.headline)
            Text(context.state.leaderboardLine)
                .font(.caption)
        }
        .activityBackgroundTint(.black.opacity(0.8))
        .activitySystemActionForegroundColor(.white)
    }
}

struct ScoreLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScoreActivityAttributes.self) { context in
            ScoreLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.roomName)
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.leaderboardLine)
                        .font(.caption)
                }
            } compactLeading: {
                Text("GR")
            } compactTrailing: {
                Text(context.state.leaderboardLine)
            } minimal: {
                Text("GR")
            }
        }
    }
}

// MARK: - Bundle

@main
struct GamesRoomWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ScoreGlanceWidget()
        ScoreLiveActivity()
    }
}
