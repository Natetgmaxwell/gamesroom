//
//  RoomService.swift
//  GamesRoom
//
//  V0.8 rooms-list service. The single source of truth for the
//  RoomPage's `LazyVStack` and the resolved last-viewed hero.
//
//  Scope of this file:
//   - Load the rooms the current user is in (via the
//     `get_my_rooms` RPC that has shipped since V0.4).
//   - Cache the result as a `@Published` array on a
//     `@MainActor @ObservableObject`.
//   - Surface load state (`isLoading`) and the last error
//     (`lastError`) for the UI to render.
//
//  Out of scope (deferred to V0.8.1):
//   - Create-room RPC (the host "Create one" CTA on the empty
//     state is a V0.9 candidate; the v0.8 shell ships the CTA
//     without a wired action).
//   - Leave-room RPC (V0.9).
//   - Update-room RPC (V0.9; RoomSettingsSheet's Save calls
//     a stub that dismisses for now).
//
//  Threading: all mutations happen on the main actor. The
//  network call uses `await` from a non-isolated context and
//  the result is assigned back on the main actor.
//

import Foundation
import SwiftUI
import Supabase

@MainActor
final class RoomService: ObservableObject {
    @Published private(set) var rooms: [Room] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    /// Re-fetch the rooms list. Safe to call from `.task` and
    /// `.refreshable`; concurrent calls coalesce (the second
    /// caller observes the same `isLoading` cycle).
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result: [Room] = try await SupabaseClientProvider.shared
                .rpc("get_my_rooms")
                .execute()
                .value
            self.rooms = result
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// Look up a room by id. The list-side cache; the authoritative
    /// read goes through `loadRoom(_:)` when the view needs
    /// server-fresh data.
    func room(withId id: UUID) -> Room? {
        rooms.first { $0.id == id }
    }
}

#if DEBUG
extension RoomService {
    /// In-memory preview service for SwiftUI previews. No network.
    /// Returns three seeded rooms spanning the role matrix.
    @MainActor
    static func preview() -> RoomService {
        let svc = RoomService()
        svc.rooms = [
            Room(
                id: UUID(),
                name: "Carwoola Crew",
                mascotName: "Borat",
                mascotPersonality: .snarky,
                mascotPoliticalIdeology: .anarchist,
                mascotApiKey: nil,
                createdBy: UUID(),
                createdAt: Date().addingTimeInterval(-86_400 * 30),
                updatedAt: Date().addingTimeInterval(-3_600),
                isLive: true,
                nextEventDescription: "Tonight 8pm",
                joinStartingBonus: 200,
                userRole: .host,
                briefing48hEnabled: true,
                calendarAutoAddHost: false,
                socialPreferencesEnabled: true,
                socialNarrationEnabled: true
            ),
            Room(
                id: UUID(),
                name: "Pluto Chess Sundays",
                mascotName: "Felix",
                mascotPersonality: .friendly,
                mascotPoliticalIdeology: .centrist,
                mascotApiKey: nil,
                createdBy: UUID(),
                createdAt: Date().addingTimeInterval(-86_400 * 90),
                updatedAt: Date().addingTimeInterval(-86_400 * 7),
                isLive: false,
                nextEventDescription: nil,
                joinStartingBonus: 200,
                userRole: .member,
                briefing48hEnabled: true,
                calendarAutoAddHost: false,
                socialPreferencesEnabled: true,
                socialNarrationEnabled: true
            ),
            Room(
                id: UUID(),
                name: "Felt Faction",
                mascotName: "Felty",
                mascotPersonality: .professional,
                mascotPoliticalIdeology: .order,
                mascotApiKey: nil,
                createdBy: UUID(),
                createdAt: Date().addingTimeInterval(-86_400 * 365),
                updatedAt: Date().addingTimeInterval(-86_400),
                isLive: false,
                nextEventDescription: nil,
                joinStartingBonus: 200,
                userRole: .member,
                briefing48hEnabled: true,
                calendarAutoAddHost: false,
                socialPreferencesEnabled: true,
                socialNarrationEnabled: true
            )
        ]
        return svc
    }
}
#endif
