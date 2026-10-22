//
//  QuestionBoxViews.swift
//  GamesRoom
//
//  V0.106 — every Question Box / Currently Into surface:
//    • ClaimedCardAskField      — the one optional line under "You're in."
//    • WhosComingList           — Briefing who's-coming + the
//                                 brought-by caption (anchor · first
//                                 night · Currently Into, V0.107)
//    • QuestionReaderCard       — the reader's full-screen card
//    • HostQuestionFallback     — the host's quiet "Sam's asking" line
//    • QuestionBoxSettingsView  — host settings + question editor
//
//  Design bar (spec §0): no new member screens except the reader card,
//  skipping is the default, never two optional fields at once.
//

import SwiftUI

// MARK: - Claimed card: one optional field (spec §1.3, §2.2, §3)

struct ClaimedCardAskField: View {
    let roomId: UUID
    let eventId: UUID

    @EnvironmentObject private var questionBox: QuestionBoxService
    @State private var text: String = ""
    @State private var seededFor: String?
    @State private var savedFlash = false
    @FocusState private var focused: Bool

    private var ask: ClaimedCardAsk { questionBox.ask(roomId: roomId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch ask {
            case .currentlyInto(let prefill):
                field(
                    label: "Currently into…",
                    placeholder: "A book, a show, a hobby",
                    limit: CurrentlyInto.maxLength,
                    identifier: "claimed-currently-into-field",
                    seed: "ci:\(prefill)",
                    initial: prefill
                ) { value in
                    await questionBox.submitCurrentlyInto(roomId: roomId, text: value)
                }
            case .question:
                field(
                    label: "Drop a question in the box (optional)",
                    placeholder: QuestionBoxHouseDeck.placeholder(seed: eventId),
                    limit: RoomQuestion.maxLength,
                    identifier: "claimed-question-field",
                    seed: "q:\(questionBox.myQuestionByEvent[eventId] ?? "")",
                    initial: questionBox.myQuestionByEvent[eventId] ?? ""
                ) { value in
                    await questionBox.submitQuestion(eventId: eventId, text: value)
                }
            case .none:
                EmptyView()
            }
        }
        .task(id: eventId) {
            await questionBox.loadClaimedCard(roomId: roomId, eventId: eventId)
        }
    }

    @ViewBuilder
    private func field(
        label: String,
        placeholder: String,
        limit: Int,
        identifier: String,
        seed: String,
        initial: String,
        submit: @escaping (String) async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            HStack(spacing: 8) {
                TextField(placeholder, text: $text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .submitLabel(.done)
                    .focused($focused)
                    .accessibilityIdentifier(identifier)
                    .onChange(of: text) { _, newValue in
                        if newValue.count > limit { text = String(newValue.prefix(limit)) }
                    }
                    .onSubmit { Task { await submit(text); flash() } }
                if savedFlash {
                    Image(systemName: Theme.Icon.checkmarkCircleFill)
                        .foregroundStyle(Theme.Palette.accent)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.hairline))
        }
        .onAppear { reseed(seed, initial) }
        .onChange(of: seed) { _, newSeed in reseed(newSeed, initial) }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { Task { await submit(text) } }
        }
    }

    private func reseed(_ seed: String, _ initial: String) {
        guard seededFor != seed, !focused else { return }
        seededFor = seed
        text = initial
    }

    private func flash() {
        withAnimation { savedFlash = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation { savedFlash = false }
        }
    }
}

// MARK: - Briefing who's-coming (spec §2.3)

struct WhosComingList: View {
    /// The room the event belongs to. Needed to resolve the anchor
    /// (`Member.invitedBy` against the active roster), the first-night
    /// signal (the leaderboard) and the room's switch.
    let roomId: UUID
    let eventId: UUID
    let rsvps: [EventRSVP]

    @EnvironmentObject private var questionBox: QuestionBoxService
    @EnvironmentObject private var roomService: RoomService

    private var claimed: [EventRSVP] { rsvps.filter { $0.state == .claimed } }

    /// The grey line under a name: anchor, first night, Currently
    /// Into, in that order (spec §2). All three parts are optional
    /// and a missing one drops out with its separator, so the room
    /// with nothing to say still renders no line at all.
    ///
    /// The Currently Into part comes from `currentlyIntoLine`, which
    /// is nil for a stale or empty value, so the staleness rule V0.106
    /// shipped is unchanged; `BroughtBy` only prefixes the "into ".
    private func caption(for rsvp: EventRSVP) -> String? {
        var anchorName: String?
        if let member = member(for: rsvp) {
            anchorName = roomService.anchorName(for: member, roomId: roomId)
        }
        return BroughtBy.caption(
            anchorName: anchorName,
            firstNight: isFirstNight(rsvp.memberId),
            currentlyInto: questionBox.currentlyIntoLine(eventId: eventId, memberId: rsvp.memberId),
            enabled: roomService.cachedShowBroughtBy(roomId: roomId)
        )
    }

    /// `EventRSVP.memberId` is the member's user id (migration 066
    /// selects `rm.user_id as member_id`), so it matches
    /// `Member.userId` directly. Nil for a member who is not on the
    /// active roster, which is also what keeps a kicked member's name
    /// off the page.
    private func member(for rsvp: EventRSVP) -> Member? {
        roomService.cachedMembers(roomId: roomId).first { $0.userId == rsvp.memberId }
    }

    /// First night = no settled session in this room yet, so the
    /// leaderboard's all-time `sessionsPlayed` is 0 (spec §4).
    /// The board lists every active member, so a member missing from
    /// it means the board has not loaded yet on this path: treat
    /// that as "not a newcomer" rather than labelling the whole room
    /// first-night on a cold open.
    private func isFirstNight(_ userId: UUID) -> Bool {
        roomService.cachedLeaderboard(roomId: roomId)
            .first { $0.userId == userId }?
            .sessionsPlayed == 0
    }

    var body: some View {
        if !claimed.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Who's coming")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                ForEach(claimed) { rsvp in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rsvp.displayName)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.primaryText)
                        if let line = caption(for: rsvp) {
                            Text(line)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.primaryText.opacity(0.5))
                                .accessibilityIdentifier("currently-into-\(rsvp.displayName)")
                                .accessibilityIdentifier("brought-by-\(rsvp.displayName)")
                        }
                    }
                }
            }
            .padding(.top, 4)
            .task(id: eventId) { await questionBox.loadEventCurrentlyInto(eventId: eventId) }
        }
    }
}

// MARK: - Reader card (spec §1.4, §1.5, speaking light)

struct QuestionReaderCard: View {
    let turn: QuestionTurn
    let onDone: () -> Void
    let onPass: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var light = SpeakingLightController(torch: AVTorch())

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("You're asking.")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.accent)
                .accessibilityIdentifier("reader-card-title")
            Spacer(minLength: 0)
            Text(QuestionTurn.ritualLine)
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
            Text(turn.questionText)
                .font(.system(size: 34, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.Palette.primaryText)
                .minimumScaleFactor(0.5)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("reader-card-question")
            if let askedBy = turn.askedBy {
                Text("asked by \(askedBy)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }
            if let line = turn.answerFirstLine {
                Text(line)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button(action: close(onDone, haptic: Haptics.success)) {
                    Text("Done")
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.Palette.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityIdentifier("reader-card-done")
                Button(action: close(onPass, haptic: Haptics.light)) {
                    Text("Pass")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.hairline))
                }
                .accessibilityIdentifier("reader-card-pass")
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.Palette.background.ignoresSafeArea())
        .onAppear { light.cardOpened(settingEnabled: turn.speakingLight) }
        .onDisappear { light.cardClosed() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { light.cardClosed() }
        }
    }

    private func close(_ action: @escaping () -> Void, haptic: @escaping () -> Void) -> () -> Void {
        { light.cardClosed(); haptic(); action() }
    }
}

// MARK: - Host fallback (spec §1.4)

struct HostQuestionFallback: View {
    let turn: QuestionTurn
    @State private var revealed = false

    var body: some View {
        Button { withAnimation { revealed.toggle() } } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: Theme.Icon.bubbleLeftAndBubbleRightFill)
                    Text("\(turn.readerDisplayName)'s asking")
                        .accessibilityIdentifier("host-fallback-reader")
                    Spacer()
                    Text(revealed ? "Hide" : "Show question")
                        .font(Theme.Typography.caption)
                }
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.accent)
                if revealed {
                    Text(turn.questionText)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText)
                        .accessibilityIdentifier("host-fallback-question")
                }
            }
            .padding(Theme.Layout.cardInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.Palette.surface)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.hairline))
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("host-question-fallback")
    }
}

// MARK: - Live-event driver

/// Attached to the room page while the active event is live. Drives
/// the lazy server tick and surfaces the host fallback.
struct QuestionBoxLiveSection: View {
    let event: Event
    let isHost: Bool

    @EnvironmentObject private var questionBox: QuestionBoxService

    var body: some View {
        // A real container, not `Group`: Group modifiers apply per child,
        // so with no turn yet (no child) the driver `.task` never ran.
        VStack(spacing: 0) {
            if isHost, let turn = questionBox.turnByEvent[event.id], !turn.isReader {
                HostQuestionFallback(turn: turn)
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: event.id) { await questionBox.driveLiveEvent(eventId: event.id) }
    }
}

// MARK: - Host settings (spec §1.1)

struct QuestionBoxSettingsView: View {
    let roomId: UUID

    @EnvironmentObject private var questionBox: QuestionBoxService
    @State private var settings = QuestionBoxSettings.default
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("Question Box", isOn: $settings.enabled)
                    .accessibilityIdentifier("qb-setting-enabled")
                Toggle("Show who asked", isOn: $settings.showAuthor)
                Toggle("House deck", isOn: $settings.houseDeck)
                Picker("A question every", selection: $settings.cadenceMinutes) {
                    ForEach(QuestionBoxSettings.cadenceOptions, id: \.self) { minutes in
                        Text(QuestionBoxCadence.label(for: minutes)).tag(minutes)
                    }
                }
                Toggle("Speaking light", isOn: $settings.speakingLight)
            } footer: {
                Text("The host asks the first question at the start time. After that it rotates to whoever's at the table, on a timer. Only the asker's phone shows it. Speaking light glows the asker's torch while their card is open.")
            }
            Section {
                NavigationLink("Questions") {
                    QuestionBoxEditorView(roomId: roomId)
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red.opacity(0.85)) }
            }
        }
        .navigationTitle("Questions")
        .task {
            settings = await questionBox.loadSettings(roomId: roomId)
            loaded = true
        }
        .onChange(of: settings) { _, newValue in
            guard loaded else { return }
            Task {
                do {
                    try await questionBox.saveSettings(roomId: roomId, settings: newValue)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

struct QuestionBoxEditorView: View {
    let roomId: UUID

    @EnvironmentObject private var questionBox: QuestionBoxService
    @State private var editing: RoomQuestion?
    @State private var adding = false

    private var all: [RoomQuestion] { questionBox.questions(roomId: roomId) }
    private var undrawn: [RoomQuestion] { all.filter { $0.drawnAt == nil } }
    private var drawn: [RoomQuestion] { all.filter { $0.drawnAt != nil } }

    var body: some View {
        List {
            Section("In the box") {
                ForEach(undrawn) { q in
                    row(q).onTapGesture { editing = q }
                }
                .onDelete { idx in
                    let ids = idx.map { undrawn[$0].id }
                    Task { for id in ids { try? await questionBox.deleteQuestion(roomId: roomId, id: id) } }
                }
            }
            if !drawn.isEmpty {
                Section("Drawn") {
                    ForEach(drawn) { q in
                        row(q)
                            .swipeActions(edge: .trailing) {
                                Button("Restore") {
                                    Task { try? await questionBox.restoreQuestion(roomId: roomId, id: q.id) }
                                }
                                .tint(Theme.Palette.accent)
                            }
                    }
                }
            }
        }
        .navigationTitle("Questions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(Text("Add a question"))
            }
        }
        .task { await questionBox.loadQuestions(roomId: roomId) }
        .sheet(item: $editing) { q in
            QuestionEditSheet(initialText: q.text, initialTag: q.tag) { text, tag in
                try await questionBox.saveQuestion(roomId: roomId, id: q.id, text: text, tag: tag)
            }
        }
        .sheet(isPresented: $adding) {
            QuestionEditSheet(initialText: "", initialTag: nil) { text, tag in
                try await questionBox.saveQuestion(roomId: roomId, id: nil, text: text, tag: tag)
            }
        }
    }

    private func row(_ q: RoomQuestion) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(q.text)
                .font(Theme.Typography.body)
            HStack(spacing: 6) {
                if let tag = q.tag { Text(tag.rawValue) }
                if q.source == .member, let author = q.authorDisplayName { Text("from \(author)") }
                if q.source == .host { Text("host") }
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.primaryText.opacity(0.5))
        }
        .contentShape(Rectangle())
    }
}

private struct QuestionEditSheet: View {
    let initialText: String
    let initialTag: QuestionTag?
    let onSave: (String, QuestionTag?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var tag: QuestionTag?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Question", text: $text, axis: .vertical)
                    .onChange(of: text) { _, v in
                        if v.count > RoomQuestion.maxLength { text = String(v.prefix(RoomQuestion.maxLength)) }
                    }
                Picker("Tag", selection: $tag) {
                    Text("None").tag(QuestionTag?.none)
                    ForEach(QuestionTag.allCases, id: \.self) { Text($0.rawValue).tag(QuestionTag?.some($0)) }
                }
                if let error { Text(error).foregroundStyle(.red.opacity(0.85)) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            do { try await onSave(text, tag); dismiss() } catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { text = initialText; tag = initialTag }
    }
}
