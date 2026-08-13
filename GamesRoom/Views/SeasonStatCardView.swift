//
//  SeasonStatCardView.swift
//  GamesRoom
//
//  V0.53 ledger-as-social-surface — the shareable stat card render.
//  One PNG per member per season, generated on the member's own device
//  and shared through the system share sheet. It is a *personal* card:
//  only the member's own numbers and public awards, never a ranking
//  position, never a badge shelf. Drowning is excluded before render.
//
//  Design tokens per the locked brand register (2026-08-10): deep
//  indigo field #23264F, warm amber accent #F5A623, coral #FF6B5E,
//  cream text #F7F3E9. Rounded rectangles and circles only. Heavy
//  confident strokes, no hairlines. One amber accent at a time. No
//  text inside any icon mark. Warm, not noir.
//

import SwiftUI

/// The stat card's brand palette (locked register, 2026-08-10).
/// Independent of `Theme.Palette` because the card is a shareable
/// artifact rendered on a light field, not an in-app dark surface.
enum StatCardPalette {
    static let indigo = Color(red: 0.137, green: 0.149, blue: 0.310)   // #23264F
    static let amber  = Color(red: 0.961, green: 0.651, blue: 0.137)   // #F5A623
    static let coral  = Color(red: 1.000, green: 0.420, blue: 0.369)   // #FF6B5E
    static let cream  = Color(red: 0.969, green: 0.953, blue: 0.914)   // #F7F3E9
}

/// The shareable stat card. Renders a `SeasonStatCard` value into a
/// fixed-size view that `ImageRenderer` exports to PNG. The card shows
/// only the member's own numbers and public awards — never a rank,
/// never a badge shelf, Drowning excluded before the value is built.
struct SeasonStatCardView: View {
    let card: SeasonStatCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: room + season as story.
            VStack(alignment: .leading, spacing: 4) {
                Text(card.roomName)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(StatCardPalette.cream)
                Text("Season \(card.seasonOrdinal)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(StatCardPalette.amber)
                if !card.seasonSubtitle.isEmpty {
                    Text(card.seasonSubtitle)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(StatCardPalette.cream.opacity(0.7))
                }
            }
            .padding(.bottom, 20)

            // Member name.
            Text(card.memberName)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(StatCardPalette.cream)
                .padding(.bottom, 20)

            // The season's record — the member's own numbers.
            VStack(alignment: .leading, spacing: 10) {
                statRow("Sessions played", "\(card.record.sessionsPlayed)")
                statRow("Net chips", signed(card.record.netChips))
                if let best = card.record.bestSingleSession {
                    statRow("Best single session", signed(best))
                }
                if let worst = card.record.worstSingleSession {
                    statRow("Worst single session", signed(worst))
                }
                statRow("Longest streak", "\(card.record.longestStreak) nights")
            }
            .padding(16)
            .background(StatCardPalette.cream.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.bottom, 20)

            // Awards — one line of earned names, never a badge shelf.
            if !card.awards.isEmpty {
                Text("Awards")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(StatCardPalette.amber)
                    .padding(.bottom, 6)
                Text(card.awards.map(\.displayName).joined(separator: " · "))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(StatCardPalette.cream)
                    .padding(.bottom, 20)
            }

            Spacer(minLength: 0)

            // One mascot line — the season's judgment in the room's voice.
            Text(card.mascotLine)
                .font(Font.custom("Fraunces", size: 14))
                .italic()
                .foregroundStyle(StatCardPalette.cream.opacity(0.85))
                .padding(.bottom, 20)

            // Quiet footer.
            Text("Games Room. Your games night, counted.")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(StatCardPalette.cream.opacity(0.5))
        }
        .padding(24)
        .frame(width: 360, height: 520, alignment: .topLeading)
        .background(StatCardPalette.indigo)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(StatCardPalette.cream.opacity(0.7))
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(StatCardPalette.cream)
        }
    }

    private func signed(_ value: Int64) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }
}
