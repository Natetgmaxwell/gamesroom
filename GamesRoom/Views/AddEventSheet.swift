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
//    3. **Pack** — `Picker` over the registered packs. The catalog is
//       intentionally hardcoded: {casino, cards_against_humanity,
//       monopoly_deal}. There is no per-room pack
//       discovery here — the host picks one of the global
//       slugs. Selecting a pack that hasn't been added to the room
//       is allowed; the server resolves it.
//
//  S3.4 adds two optional fields, **Venue** and **Note**, so one
//  sheet sets the night up. The packs are a set: the headline is the
//  first selected pack in display order, not the last one tapped.
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
    /// S3.4 — seeded by `initialPlayedAt` when the caller knows the
    /// night already (the room's next slot), otherwise the default
    /// three weeks out.
    @State private var playedAt: Date
    /// S3.4 — optional venue and note. One sheet sets the night up.
    @State private var venue: String = ""
    @State private var note: String = ""
    /// What the table is playing tonight: optional labels, never the
    /// scoring. Every night is scored in chips, so casino is always on
    /// and is VISIBLE here — a pre-ticked row the host cannot untick.
    /// The label informs; the save semantics never depended on a tick
    /// (`save()` files casino first either way: it is the headline
    /// `pack_slug` the server and older builds read).
    @State private var packSlugs: [String] = []


    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    /// S1.5 + S3.4 — `initialPlayedAt` seeds the date only: "Plan the
    /// next night" passes tonight + 7 days, and a caller that has no
    /// date keeps the sheet's own default. The parameter exists in
    /// both lanes with the same name and type, so callers can pass it
    /// positionally or by label.
    ///
    /// 1.2.5 — `initialPackSlugs` pre-selects the games ("Pick another
    /// time" passes the settled night's packs). Casino is always on and
    /// is listed first, but it is not part of the tickable set: the
    /// seed drops it so the rows and the tick state cannot disagree.
    /// `save()` files it first either way.
    init(roomId: UUID, initialPlayedAt: Date? = nil, initialPackSlugs: [String] = [], onSaved: @escaping (UUID) -> Void) {
        self.roomId = roomId
        self.onSaved = onSaved
        _playedAt = State(initialValue: initialPlayedAt ?? AddEventSheet.defaultPlayedAt())
        // The casino slug is dropped from the seed on purpose: it is
        // always on and is rendered as a pre-ticked readonly row, so
        // it must never sit in the tickable set. This is the dedupe
        // guard, not a display filter — the casino ROW is listed.
        // The rule lives in `NightPackPicker` so the picker and the
        // test pin one copy of it.
        _packSlugs = State(initialValue: NightPackPicker.tickableSet(seed: initialPackSlugs))

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
                    ForEach(availablePacks) { option in
                        packRow(option)
                    }
                    .tint(Theme.Palette.accent)
                } header: {
                    Text("What are you playing?")
                } footer: {
                    Text("Optional. Play anything: winners get paid in chips, and everyone scans their chips at the end.")
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

                Section {
                    TextField("Venue", text: $venue)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Venue")
                } footer: {
                    Text("Optional. Where the night is.")
                }

                Section {
                    TextField(
                        "Note for the table",
                        text: $note,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .onChange(of: note) { _, newValue in
                        if newValue.count > 280 {
                            note = String(newValue.prefix(280))
                        }
                    }
                } header: {
                    Text("Note")
                } footer: {
                    Text("Optional. A short note for the table. \(note.count)/280")
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

    /// The default event name — "tue 10 nov · 7pm session" — computed
    /// off the currently selected `playedAt`. The format lives in
    /// `EventDefaultName` because the edit-time flow needs the same
    /// string for the old and the new time (fx30).
    private var defaultEventName: String {
        EventDefaultName.name(for: playedAt)
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
    ///
    /// Casino is NOT filtered out of the catalog any more: the pack
    /// is always on, so the host has to SEE it. The rows come from
    /// `NightPackPicker.rows()` — the registry's catalog with the
    /// always-on pack first — so the order the host sees is the
    /// registry's own order (`PackRegistry.defaultPacks`).
    private var availablePacks: [PackOption] {
        NightPackPicker.rows().compactMap { slug in
            guard let definition = PackRegistry.shared.definition(for: slug) else { return nil }
            return PackOption(slug: definition.slug, displayName: definition.displayName)
        }
    }

    /// One row in "What are you playing?". Casino is always on, so
    /// it renders as a pre-ticked readonly row — never as a choice
    /// the host could untick. Every other pack is a plain toggle.
    @ViewBuilder
    private func packRow(_ option: PackOption) -> some View {
        if NightPackPicker.isAlwaysOn(option.slug) {
            alwaysOnPackRow
        } else {
            Button {
                togglePack(option.slug)
            } label: {
                HStack {
                    Text(option.displayName)
                        .foregroundStyle(Theme.Palette.primaryText)
                    Spacer()
                    if packSlugs.contains(option.slug) {
                        Image(systemName: Theme.Icon.checkmarkCircleFill)
                            .foregroundStyle(Theme.Palette.accent)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// The always-on casino row: pre-ticked and not a button, so it
    /// cannot be unticked. The caption states the rule the host
    /// would otherwise have to guess at.
    private var alwaysOnPackRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CasinoPack.displayName)
                    .foregroundStyle(Theme.Palette.primaryText)
                Text("Every night runs on casino chips")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
            Spacer(minLength: 8)
            Image(systemName: Theme.Icon.checkmarkCircleFill)
                .foregroundStyle(Theme.Palette.accent)
        }
    }

    /// S3.4 — the games are a set, kept in display order. None is
    /// fine: the night is a chips night either way.
    private func togglePack(_ slug: String) {
        // Casino is always on: its row is readonly, so the slug must
        // never enter (or leave) the tickable set. `save()` files it
        // first regardless of what the host does here.
        guard !NightPackPicker.isAlwaysOn(slug) else { return }
        if let idx = packSlugs.firstIndex(of: slug) {
            packSlugs.remove(at: idx)
        } else {
            packSlugs.append(slug)
        }
        packSlugs.sort { packOrder[$0, default: .max] < packOrder[$1, default: .max] }
    }

    /// The display order of the pack picker, used to keep the
    /// selected set in the order it is shown.
    private var packOrder: [String: Int] {
        Dictionary(
            uniqueKeysWithValues: availablePacks.enumerated().map { ($0.element.slug, $0.offset) }
        )
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
        // Chips first, always: the casino pack is how every night is
        // scored, and the first slug is the event's headline pack.
        let packSlugs = [CasinoPack.slug] + self.packSlugs.filter { $0 != CasinoPack.slug }
        for slug in packSlugs where !PackRegistry.shared.isRegistered(slug: slug) {
            errorMessage = "Unknown game: \(slug)."
            return
        }

        do {
            let newEventId = try await roomService.addEvent(
                roomId: roomId,
                name: resolvedEventName,
                playedAt: playedAt,
                packSlugs: packSlugs
            )
            // S3.4 — the venue and the note go on the night that was
            // just created. A failure here does not undo the night:
            // the host can add the note from Edit details.
            let trimmedVenue = venue.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedVenue.isEmpty || !trimmedNote.isEmpty {
                try? await roomService.updateEventMemberFields(
                    eventId: newEventId,
                    note: trimmedNote.isEmpty ? nil : trimmedNote,
                    venue: trimmedVenue.isEmpty ? nil : trimmedVenue
                )
            }
            await roomService.eventDidChange(eventId: newEventId)
            Haptics.success()
            onSaved(newEventId)
            dismiss()
        } catch {
            errorMessage = ServerErrorCode.code(in: error)?.message
                ?? (error as NSError).localizedDescription
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
