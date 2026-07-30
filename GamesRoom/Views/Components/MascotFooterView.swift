import SwiftUI

/// One-line mascot voice rendered as a footer caption beneath the
/// leaderboard. Same engine call as `MascotBubble` but with no card
/// chrome — personality lives in the margins, not in a hero.
///
/// Long-press reveals the full `MascotBubble` for the deep-dive read.
struct MascotFooterView: View {
    let mascotName: String
    let roomName: String
    let personality: MascotPersonality
    let ideology: MascotPoliticalIdeology
    let context: MascotEngine.RoomContext
    let hosting: MascotEngine.HostingConfig?

    @Environment(\.horizontalSizeClass) private var hSize
    @State private var line: String?
    @State private var restingReason: MascotEngine.MascotError?
    @State private var isLoading: Bool = false
    @State private var showingFullBubble: Bool = false

    @ObservedObject private var engine = MascotEngine.shared

    private var contentPadding: CGFloat { 16 }

    var body: some View {
        Group {
            if isLoading {
                Text("\(mascotName) is thinking…")
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let line {
                Text(line)
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(restingFallback)
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, contentPadding)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { showingFullBubble = true }
        .onLongPressGesture(minimumDuration: 0.5) { showingFullBubble = true }
        .sheet(isPresented: $showingFullBubble) {
            MascotBubble(
                mascotName: mascotName,
                roomName: roomName,
                personality: personality,
                ideology: ideology,
                context: context,
                hosting: hosting
            )
            .presentationDetents([.medium, .large])
        }
        .task(id: engine.refreshTrigger) { await regenerate() }
    }

    private var restingFallback: String {
        switch restingReason {
        case .unavailable:
            return "\(mascotName) is resting."
        case .generationFailed(let message):
            return message.isEmpty ? "\(mascotName) couldn't think of anything." : message
        case nil:
            return "\(mascotName) is resting."
        }
    }

    private func regenerate() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let result = await engine.generateOneLiner(
            mascotName: mascotName,
            roomName: roomName,
            personality: personality,
            ideology: ideology,
            context: context,
            hosted: hosting
        )
        switch result {
        case .success(let text):
            line = text
            restingReason = nil
        case .failure(let error):
            line = nil
            restingReason = error
        }
    }
}
