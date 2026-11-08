//
//  QuestionBoxViews.swift
//  GamesRoom
//
//  V0.106 — every Question Box / Currently Into surface:
//    • ClaimedCardAskField      — the one optional line under "You're in."
//    • QuestionReaderCard       — the reader's full-screen card
//    • HostQuestionFallback     — the host's quiet "Sam's asking" line
//    • QuestionBoxSettingsView  — host settings + question editor
//
//  v1.2.2 S6 T3/T4 — `WhosComingList` (the briefing who's-coming list
//  and the brought-by caption it carried) is deleted: who claimed a
//  seat is read off the seat grid, and since T4 the caption lives in
//  the seat popover on `SeatGridRow`, built by the same four inputs
//  this file's list used. The event's Currently Into rows it loaded
//  are still loaded — the event card owns that `.task`, and
//  `SeatGridRow` reads the same cache.
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
        VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.secondaryText)
            HStack(spacing: Theme.Layout.cardLineGap) {
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
            .padding(Theme.Layout.fieldInset)
            .overlay(RoundedRectangle(cornerRadius: Theme.Layout.smallRadius).stroke(Theme.Palette.hairline))
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

// MARK: - Reader card (spec §1.4, §1.5, speaking light)

struct QuestionReaderCard: View {
    let turn: QuestionTurn
    let onDone: () -> Void
    let onPass: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var light = SpeakingLightController(torch: AVTorch())

    var body: some View {
        // v1.2.4 S4.7 — the reader card is on the system now. Its
        // margin is the app's full-screen margin (`gutter`), the
        // question wears the app's display serif (`displayLarge`), and
        // the card's groups sit `roomSectionGap` apart. The question
        // block itself is one group: the ritual line, the question and
        // its two meta lines sit `cardLineGap` apart.
        VStack(alignment: .leading, spacing: Theme.Layout.roomSectionGap) {
            Text("You're asking.")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.accent)
                .accessibilityIdentifier("reader-card-title")
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: Theme.Layout.cardGroupGap) {
            VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
                Text(QuestionTurn.ritualLine)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.labelText)
                Text(turn.questionText)
                    .font(Theme.Typography.displayLarge)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .minimumScaleFactor(0.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("reader-card-question")
            }
            // TARS review: the question and its meta lines are two groups,
            // so "Pick who answers first" no longer sits on the question.
            VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
                if let askedBy = turn.askedBy {
                    Text("asked by \(askedBy)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
                if let line = turn.answerFirstLine {
                    Text(line)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.labelText)
                }
            }
            }
            Spacer(minLength: 0)
            // v1.2.4 S4.7 — one primary action per screen: Done is the
            // app's one primary button, full width, and Pass is the app's
            // one secondary underneath it. They are no longer two
            // equal-weight halves of a row.
            VStack(spacing: Theme.Layout.cardGroupGap) {
                Button(action: close(onDone, haptic: Haptics.success)) {
                    Text("Done")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("reader-card-done")
                // v1.2.4 S4.3 — the pass is the app's one secondary
                // style: a grey caption, no outline box, so it stops
                // reading as a peer of the Done primary.
                SecondaryTextAction(title: "Pass", action: close(onPass, haptic: Haptics.light))
                    .accessibilityIdentifier("reader-card-pass")
            }
        }
        .padding(Theme.Layout.gutter)
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
            VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
                HStack(spacing: Theme.Layout.cardLineGap) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            // v1.2.4 S4.4 — one card shape: the host fallback's
            // hand-rolled 1pt-stroke box is now a `sectionCard`, so it
            // matches the cards around it.
            .sectionCard(.standard)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("host-question-fallback")
    }
}

// MARK: - Live-event driver

/// Attached to the room page while the active event is live. Drives
/// the lazy server tick and surfaces the host fallback.
///
/// v1.2.2 S6 T6 — the driver moved up to `RoomDetailView`, which is
/// where it belongs now that the room page asks `hasContent` before
/// adding this section at all: a container with nothing inside
/// renders zero-height yet still claims a `roomSectionGap` above AND
/// below it, which is what pushed the live card twice as far from
/// Standings as every other section pair. The driver used to live
/// here, so it could only run once the section was on the page —
/// which it now is only once a turn exists to print. One driver,
/// started by the page, before the section it feeds.
struct QuestionBoxLiveSection: View {
    let event: Event
    let isHost: Bool

    @EnvironmentObject private var questionBox: QuestionBoxService

    var body: some View {
        VStack(spacing: 0) {
            if let turn = visibleTurn {
                HostQuestionFallback(turn: turn)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The turn the host is being asked to read, or nil when there is
    /// nothing to show. Same predicate as `hasContent`, so the page
    /// and this card can never disagree about whether to render.
    private var visibleTurn: QuestionTurn? {
        guard Self.hasContent(event: event, isHost: isHost, turns: questionBox.turnByEvent)
        else { return nil }
        return questionBox.turnByEvent[event.id]
    }

    /// Whether the driver has a fallback to print for this event.
    /// The room page needs this BEFORE it adds the section (see the
    /// note above), which is why it is a static on the section and
    /// not a property.
    static func hasContent(
        event: Event,
        isHost: Bool,
        turns: [UUID: QuestionTurn]
    ) -> Bool {
        guard isHost, let turn = turns[event.id] else { return false }
        return !turn.isReader
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
                Section { Text(error).foregroundStyle(Theme.Palette.loss) }
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
        VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
            Text(q.text)
                .font(Theme.Typography.body)
            HStack(spacing: Theme.Layout.cardLineGap) {
                if let tag = q.tag { Text(tag.rawValue) }
                if q.source == .member, let author = q.authorDisplayName { Text("from \(author)") }
                if q.source == .host { Text("host") }
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.secondaryText)
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
                if let error { Text(error).foregroundStyle(Theme.Palette.loss) }
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
