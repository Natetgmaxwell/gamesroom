//
//  PackHowTo.swift
//  GamesRoom
//
//  Track V0.9 Wave 2 Slice 2.1 - per-pack how-to content. The
//  V0.8 picker surfaces each pack's name + icon + scoring type,
//  but the rules + setup + scoring details lived only in the
//  handoff notes. Wave 2 Slice 2.1 ships the rules text inside
//  the iOS bundle so the picker can drill into a PackDetailView
//  and show the how-to body without a server round-trip.
//
//  Per-pack content is bundled as a Codable struct + a per-slug
//  fixture (the file-level `bundled` dictionary). The catalog is
//  intentionally local: a pack that ships without a how-to slug
//  shows a generic "rules coming soon" placeholder so the picker
//  still renders. Server-side pack how-tos are a V2 concern
//  (per the V0.9 roadmap Wave 2 notes).
//

import Foundation

/// How-to content for a single pack. Displayed in
/// `PackDetailView` when a member taps a pack row in the
/// settings sheet.
struct PackHowTo: Codable, Hashable {
    /// Short headline shown above the body (e.g. "How to play Casino").
    let headline: String

    /// One-line summary shown under the headline.
    let summary: String

    /// Ordered list of how-to sections. Each section has a title
    /// and a body string (markdown NOT supported - the text is
    /// rendered verbatim).
    let sections: [Section]

    /// One section of how-to content. Renders as a title + body
    /// pair in the detail view.
    struct Section: Codable, Hashable, Identifiable {
        let id: UUID
        let title: String
        let body: String

        init(id: UUID = UUID(), title: String, body: String) {
            self.id = id
            self.title = title
            self.body = body
        }
    }

    init(headline: String, summary: String, sections: [Section]) {
        self.headline = headline
        self.summary = summary
        self.sections = sections
    }
}

/// Catalog of how-to content keyed by pack slug. Bundled
/// fixtures cover the four V0.8 packs; unknown slugs return
/// `nil` so callers can render a "coming soon" placeholder.
enum PackHowToCatalog {
    /// Looks up the how-to for a pack slug. Returns `nil` for
    /// slugs without bundled content (the detail view renders
    /// a placeholder in that case).
    static func howTo(forSlug slug: String) -> PackHowTo? {
        return bundled[slug]
    }

    /// Per-slug fixtures. Each pack's content was written from
    /// the same source the V0.8 picker description came from
    /// (no new game design introduced in this slice).
    private static let bundled: [String: PackHowTo] = [
        "casino": PackHowTo(
            headline: "How to play Casino",
            summary: "Virtual-chip casino. Each player withdraws chips at the start of the round and returns the count of chips in front of them at the end. The app records the net delta per member.",
            sections: [
                PackHowTo.Section(
                    title: "Setup",
                    body: "Host creates an event with the Casino pack. Each member claims a seat. The starting withdrawal amount is set per room (default 10 virtual chips)."
                ),
                PackHowTo.Section(
                    title: "Play",
                    body: "Play your game of choice at the table - poker, blackjack, or anything chip-based. The app does not run the game; the table does."
                ),
                PackHowTo.Section(
                    title: "Settle",
                    body: "At the end of the night each member opens the Casino sheet on their own phone, enters the chips in front of them, and submits. The host finalises after every member has scanned. Default: any member who has not scanned within 24 hours is treated as returned-to-start (net delta zero)."
                ),
                PackHowTo.Section(
                    title: "Scoring",
                    body: "Withdraw-return scoring: each member's net delta (returned minus withdrawn) is recorded as a season-score change. There is no single winner; the leaderboard tracks cumulative net positive."
                ),
                PackHowTo.Section(
                    title: "Photos",
                    body: "The chip-scan flow supports per-member photos of the chip stack. The default is to discard the photo and keep only the hash + vision snapshot - the original image is never uploaded."
                )
            ]
        ),
        "cards_against_humanity": PackHowTo(
            headline: "How to play Cards Against Humanity",
            summary: "Card-judging party game. The judge's pick wins the round and keeps the black card; your score is the number of cards you hold at session end.",
            sections: [
                PackHowTo.Section(
                    title: "Setup",
                    body: "Use the physical CAH deck at the table. The app does not run the game. Pick a round's judge before play starts."
                ),
                PackHowTo.Section(
                    title: "Play",
                    body: "Each non-judge player answers the round's prompt card. The judge picks the funniest answer. The judge's pick wins the round and keeps the black card."
                ),
                PackHowTo.Section(
                    title: "Score",
                    body: "Count-based scoring: the host enters the number of cards the winner takes per round (usually 1). The winner's card count goes up by that amount. The room's payout override does not apply — the count IS the score."
                ),
                PackHowTo.Section(
                    title: "Rounds",
                    body: "There is no set number of rounds. The room's session ends when the host settles it. Multiple rounds per session are normal; each round adds the cards-won count to the winner's tally."
                ),
                PackHowTo.Section(
                    title: "Scan",
                    body: "At session end each member can scan their stack of won black cards on their own phone. The app counts the cards, the member confirms or adjusts, and the tally is recorded as the authoritative count for the night. Re-scan converges."
                )
            ]
        ),
        "monopoly_deal": PackHowTo(
            headline: "How to play Monopoly Deal",
            summary: "Card-based Monopoly. Winner of the round (last player with cards in hand) takes the pot.",
            sections: [
                PackHowTo.Section(
                    title: "Setup",
                    body: "Use the physical Monopoly Deal deck. Each player starts with 5 cards. Deal 5 cards to each player."
                ),
                PackHowTo.Section(
                    title: "Play",
                    body: "Play follows the standard Monopoly Deal rules (draw 2, play up to 3 cards, max 7 in hand). The last player with cards still in hand (not yet won 3 complete property sets) is the round's loser; everyone else wins."
                ),
                PackHowTo.Section(
                    title: "Score",
                    body: "Single-winner scoring: the host picks the round's winner from the member list. The winner earns one win-point on the season score."
                ),
                PackHowTo.Section(
                    title: "V0.9.1 - multi-winner / split-the-pot",
                    body: "The current model is single-winner. A future version may add multi-winner scoring (e.g. for tournaments) - deferred per the V0.9 roadmap Q-MONOPOLY-MULTIWINNER."
                )
            ]
        ),
        "pluto_chess": PackHowTo(
            headline: "How to play Pluto Chess",
            summary: "Chess-variant pack. Winner of the game earns one point on the season score.",
            sections: [
                PackHowTo.Section(
                    title: "Setup",
                    body: "Use a physical chess board. Pick a colour. The app does not run the game; the board does."
                ),
                PackHowTo.Section(
                    title: "Play",
                    body: "Standard chess rules apply. The pack supports one game per round; the round's winner is the player who checkmates the opponent."
                ),
                PackHowTo.Section(
                    title: "Score",
                    body: "Single-winner scoring: the host picks the round's winner from the member list. Draws are recorded as a 0-0 (no winner) and no win-point is awarded."
                )
            ]
        )
    ]
}
