import SwiftUI

struct GamesPage: View {
    @EnvironmentObject private var roomService: RoomService
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var packs: [PackSummary] = []
    @State private var loading = true

    private var gutter: CGFloat { Theme.Layout.gutter(for: hSize) }
    private var gridMin: CGFloat { Theme.Layout.gridCellMin(for: hSize) }
    private var contentMaxWidth: CGFloat? { Theme.Layout.contentMaxWidth(for: hSize) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("Games")
                        .font(Theme.displayFont)
                        .foregroundStyle(Theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 8)

                    if loading {
                        ProgressView()
                            .tint(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                    } else if packs.isEmpty {
                        Text("No packs available")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.top, 48)
                    } else if hSize == .regular {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: gridMin), spacing: 16)], spacing: 16) {
                            ForEach(packs) { pack in
                                PackRow(pack: pack)
                                    .padding(Theme.Layout.cardInset(for: hSize))
                                    .background(Theme.cardSurface)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    } else {
                        ForEach(packs) { pack in
                            PackRow(pack: pack)
                        }
                    }
                }
                .padding(.horizontal, gutter)
                .padding(.top, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: contentMaxWidth, alignment: .center)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { try? await loadPacks() }
    }

    private func loadPacks() async {
        packs = await roomService.listAvailablePacks()
        loading = false
    }
}

struct PackRow: View {
    let pack: PackSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pack.displayName)
                .font(.system(size: 22, weight: .regular, design: .serif))
                .foregroundStyle(Theme.primaryText)

            if let desc = pack.description {
                Text(desc)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
            }

            Text(scoringLabel)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var scoringLabel: String {
        switch pack.scoringType {
        case "withdraw_return":
            return "Scoring: withdraw + return"
        default:
            return "Scoring: single winner"
        }
    }
}
