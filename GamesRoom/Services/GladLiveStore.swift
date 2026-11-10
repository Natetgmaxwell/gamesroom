//
//  GladLiveStore.swift
//  GamesRoom
//
//  1.2.5 Task 4 — the Supabase side of `GladStore`. A plain table
//  read and insert on `public.glad_you_came` (migration 119): RLS is
//  the whole gate, so there is no RPC to call and none to misuse.
//

import Foundation
import Supabase

struct LiveGladStore: GladStore {
    static let shared = LiveGladStore()

    private struct Row: Encodable {
        let eventId: UUID
        let fromUser: UUID
        let toUser: UUID
        enum CodingKeys: String, CodingKey {
            case eventId = "event_id"
            case fromUser = "from_user"
            case toUser = "to_user"
        }
    }

    func fetchNotes(eventId: UUID, viewerId: UUID) async throws -> [GladNote] {
        // RLS already limits this to rows the caller sent or received;
        // the `or` only keeps the query honest about what it wants.
        try await SupabaseClientProvider.shared
            .from("glad_you_came")
            .select("event_id, from_user, to_user, created_at")
            .eq("event_id", value: eventId.uuidString)
            .or("from_user.eq.\(viewerId.uuidString),to_user.eq.\(viewerId.uuidString)")
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    func send(eventId: UUID, from viewerId: UUID, to recipients: [UUID]) async throws {
        let rows = recipients
            .filter { $0 != viewerId }
            .map { Row(eventId: eventId, fromUser: viewerId, toUser: $0) }
        guard !rows.isEmpty else { return }
        // ON CONFLICT DO NOTHING: sending twice to the same person for
        // the same night does nothing. `.minimal` so the insert needs no
        // read-back.
        _ = try await SupabaseClientProvider.shared
            .from("glad_you_came")
            .upsert(rows, onConflict: "event_id,from_user,to_user", returning: .minimal, ignoreDuplicates: true)
            .execute()
    }
}

enum GladStores {
    /// The store the recap uses. The screenshot sweep runs against the
    /// in-memory twin, like `RoomService` does.
    static var current: GladStore {
        #if DEBUG
        if CommandLine.arguments.contains("-screenshots-bypass-auth") {
            return InMemoryGladStore.shared
        }
        #endif
        return LiveGladStore.shared
    }
}
