//
//  AddEventSheet.swift
//  GamesRoom
//
//  Track E2 — host creates a new event in a room.
//
//  Presented by `RoomDetailView` from the host-only "+ Add an event"
//  CTA. Owns the three inputs the create-event flow surfaces to the
//  user in V0.8:
//
//    1. **Name** — free text. Defaults to "<weekday d MMM · ha>
//       session" so empty submissions still produce a usable chapter
//       title. Trimmed on save; blank falls back to the default.
//    2. **When** — `DatePicker`. Defaults to *tomorrow at 19:00*.
//       The default is local-time and rounded to the hour, matching
//       the "Saturday 8pm" voice the mascot uses in the briefing.
//    3. **Pack** — `Picker` over the four V0.8 packs. The catalog is
//       intentionally hardcoded: {casino, cards_against_humanity,
//       monopoly_deal, pluto_chess}. There is no per-room pack
//       discovery here — the host picks one of the four global
//       slugs. Selecting a pack that hasn't been added to the room
//       is allowed; the server resolves it.
//
//  After a successful create the sheet dismisses and calls
//  `onSaved(newEventId)`. The parent (`RoomDetailView`) uses the id
//  to refresh its event list and surface the new event in the
//  appropriate slot.
//
//  Failure mode
//  ------------
//  The RPC failure collapses to a red inline message under the form.
//  The user can edit and retry without losing input. There is no
//  retry-on-network-flap logic — the parent handles retry at a higher
//  level (e.g. via `RoomService.refresh`).
//
//  Theme discipline
//  ----------------
//  All styling routes through `Theme.Palette`, `Theme.Typography`,
//  `Theme.Layout`, and the `.sectionCard(...)` modifier. No ad-hoc
//  colors, no inline hex. The form uses standard SwiftUI `Form`
//  styling tuned to the V0.8 palette via `.scrollContentBackground`
//  + `.background(Theme.Palette.background)`.
//

import SwiftUI

// MARK: - AddEventSheet

struct AddEventSheet: View {
    let roomId: UUID
    let onSaved: (UUID) -> Void

    @EnvironmentObject private var roomService: RoomService
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var playedAt: Date = AddEventSheet.defaultPlayedAt()
    @State private var packSlug: String = AddEventSheet.initialPackSlug

    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    init(roomId: UUID, onSaved: @escaping (UUID) -> Void) {
        self.roomId = roomId
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "Name",
                        text: $name,
                        prompt: Text(defaultEventName)
                    )
                    .textInputAutocapitalization(.words)
                } header: {
                    Text("Event name")
                } footer: {
                    Text("Leave blank to use \"\(defaultEventName)\".")
                }

                Section {
                    Picker("Pack", selection: $packSlug) {
                        ForEach(availablePacks) { option in
                            Text(option.displayName).tag(option.slug)
                        }
                    }
                    .tint(Theme.Palette.accent)
                } header: {
                    Text("Pack")
                } footer: {
                    Text("Pick the pack this event will use.")
                }

                Section {
                    DatePicker(
                        "When",
                        selection: $playedAt,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .tint(Theme.Palette.accent)
                } header: {
                    Text("Date & time")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.red.opacity(0.85))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle("New event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Palette.primaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                    .tint(Theme.Palette.accent)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Defaults

    /// The default `playedAt` — three weeks out at 19:00 local.
    /// V0.95 F adopts the 2-Hour Cocktail Party planning rule
    /// (Nick Gray): parties work when planned ~3 weeks ahead — long
    /// enough for calendars, short enough to stay real. The host can
    /// still pick any date; this is the starting suggestion.
    static func defaultPlayedAt() -> Date {
        let calendar = Calendar.current
        let threeWeeks = calendar.date(byAdding: .day, value: 21, to: Date()) ?? Date()
        return calendar.date(bySettingHour: 19, minute: 0, second: 0, of: threeWeeks) ?? threeWeeks
    }

    /// The default event name — "<weekday d MMM · ha> session" —
    /// computed off the currently selected `playedAt`. Lowercased so
    /// the briefing card and the chapter title look like a casual
    /// sentence ("fri 1 aug · 7pm session"), not a system timestamp.
    private var defaultEventName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "EEE d MMM · ha"
        let stamp = formatter.string(from: playedAt).lowercased()
        return "\(stamp) session"
    }

    /// The resolved event name — trimmed input if non-empty, the
    /// default otherwise. Mirrors v0.7.1 behavior: an empty name is
    /// not an error, just a fall-through.
    private var resolvedEventName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultEventName : trimmed
    }

    // MARK: - Pack catalog
    //
    /// The V0.8 pack catalog is sourced from `PackRegistry.shared`
    /// (per migration 034 seed ordering). The picker reads from the
    /// registry so adding a new pack only requires a new struct in
    /// `Packs.swift` and an entry in `PackRegistry.defaultPacks`.
    /// The catalog is filtered through `PackRegistry.shared.isRegistered(slug:)`
    /// on save so the host can never submit a slug the server doesn't
    /// know about.
    private var availablePacks: [PackOption] {
        PackRegistry.shared.allPacks.map {
            PackOption(slug: $0.slug, displayName: $0.displayName)
        }
    }

    private static var initialPackSlug: String {
        PackRegistry.shared.allPacks.first?.slug ?? "casino"
    }

    // MARK: - Save

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        // P0.3 acceptance criterion: "Add-event selection uses
        // catalog data and cannot submit a slug absent from the
        // server catalog." Refuse unknown slugs at the form layer
        // so the host sees a clear error before the network round-
        // trip.
        guard PackRegistry.shared.isRegistered(slug: packSlug) else {
            errorMessage = "Unknown pack: \(packSlug). Pick one of the registered packs."
            return
        }

        do {
            let newEventId = try await roomService.addEvent(
                roomId: roomId,
                name: resolvedEventName,
                playedAt: playedAt,
                packSlug: packSlug
            )
            onSaved(newEventId)
            dismiss()
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }
}

// MARK: - PackOption

/// One option in the pack picker. Pure value type — kept
/// file-local because no other surface consumes it.
struct PackOption: Identifiable, Hashable {
    let slug: String
    let displayName: String
    var id: String { slug }
}

#if DEBUG
#Preview("Add event") {
    AddEventSheet(
        roomId: UUID(),
        onSaved: { _ in }
    )
    .environmentObject(PreviewSupport.roomService())
    .preferredColorScheme(.dark)
}
#endif

// MARK: - Preview support
//
// Same shim as RoomPage — only used inside `#Preview` so this file
// compiles in isolation while the service layer lands in Track D2.
// `RoomService.preview()` is a stub on the service type and only
// resolves when DEBUG.
#if DEBUG
private enum PreviewSupport {
    @MainActor
    static func roomService() -> RoomService { RoomService.preview() }
}
#endif
