//
//  SocialPreference.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// Per-member social preferences surfaced on the MemberNotes card.
///
/// Both fields are host-visible only. Consent gating is enforced at
/// the Supabase RLS layer, not in this type. The V0.8 brief renames
/// the surface to "how to host me" so the asymmetry is implicit —
/// that label lives at the UI layer.
struct SocialPreference: Codable, Hashable {
    /// ≤140 chars. What the member wants the host to know about how
    /// they like to be treated in the room.
    var socialText: String

    /// ≤280 chars. Broadcast in the Briefing as a conversation
    /// prompt for the whole room.
    var conversationPrompt: String

    /// Whether the app has already pre-set the default preference
    /// for this member. Used by the UI to decide whether to render
    /// the "set your preferences" nudge.
    var defaultSet: Bool

    /// Empty default. UI substitutes the canonical default text
    /// before the first write when this is returned.
    static let empty = SocialPreference(
        socialText: "",
        conversationPrompt: "",
        defaultSet: false
    )

    /// Canonical default shown to new members before they edit.
    static let defaultSocialText =
        "I prefer to be introduced by name; please don't single me out without warning."

    enum CodingKeys: String, CodingKey {
        case socialText = "preferences_social"
        case conversationPrompt = "preferences_conversation_prompt"
        case defaultSet = "preferences_default_set"
    }

    init(socialText: String, conversationPrompt: String, defaultSet: Bool) {
        self.socialText = socialText
        self.conversationPrompt = conversationPrompt
        self.defaultSet = defaultSet
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        socialText = try c.decodeIfPresent(String.self, forKey: .socialText) ?? ""
        conversationPrompt = try c.decodeIfPresent(String.self, forKey: .conversationPrompt) ?? ""
        defaultSet = try c.decodeIfPresent(Bool.self, forKey: .defaultSet) ?? false
    }
}
