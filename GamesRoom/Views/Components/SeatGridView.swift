import SwiftUI

// MARK: - SeatGridView
//
// An N-row grid of seats for a single games-night table. Each seat is in one
// of three states:
//
//   - `.claimed(name:)` — another member claimed it; show their initial.
//   - `.available` — open seat.
//   - `.yours` — the local member's seat. Always highlighted.
//
// The grid uses `LazyVGrid` with a flexible column count so it adapts to
// table size (4, 6, 8 seats) and to iPhone/iPad width. Each seat is a
// rounded square; tappable seats can be wired by the parent.
//
// Usage:
//     SeatGridView(
//         seats: [
//             .yours,
//             .claimed(name: "Thea"),
//             .available,
//             .claimed(name: "Marco"),
//         ],
//         columns: 4,
//         onTapSeat: { index in ... }
//     )
struct SeatGridView: View {

    enum Seat: Identifiable, Equatable {
        case yours
        case claimed(name: String)
        case available

        var id: String {
            switch self {
            case .yours:                      return "you"
            case .claimed(let name):          return "claimed-\(name)"
            case .available:                  return "available"
            }
        }
    }

    let seats: [Seat]
    let columns: Int
    let onTapSeat: ((Int) -> Void)?

    init(seats: [Seat], columns: Int = 4, onTapSeat: ((Int) -> Void)? = nil) {
        self.seats = seats
        self.columns = max(1, columns)
        self.onTapSeat = onTapSeat
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 12),
            count: columns
        )
    }

    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: 12) {
            ForEach(Array(seats.enumerated()), id: \.element.id) { index, seat in
                seatCell(for: seat, at: index)
            }
        }
    }

    // MARK: Seat cell

    @ViewBuilder
    private func seatCell(for seat: Seat, at index: Int) -> some View {
        let cell = seatBody(for: seat)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(background(for: seat))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(border(for: seat), lineWidth: borderWidth(for: seat))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityElement()
            .accessibilityLabel(Text(accessibilityLabel(for: seat, at: index)))
            .accessibilityAddTraits(onTapSeat != nil ? .isButton : [])

        if let onTapSeat {
            Button(action: { onTapSeat(index) }) {
                cell
            }
            .buttonStyle(.plain)
        } else {
            cell
        }
    }

    @ViewBuilder
    private func seatBody(for seat: Seat) -> some View {
        switch seat {
        case .yours:
            VStack(spacing: 4) {
                Image(systemName: Theme.Icon.chairFill)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.accent)
                Text("Your seat")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
            }
        case .claimed(let name):
            VStack(spacing: 4) {
                Image(systemName: Theme.Icon.personFill)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                Text(initial(for: name))
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.primaryText)
                Text(name)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.6))
                    .lineLimit(1)
            }
        case .available:
            VStack(spacing: 4) {
                Image(systemName: Theme.Icon.chair)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.3))
                Text("open")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.4))
            }
        }
    }

    // MARK: Visual helpers

    private func background(for seat: Seat) -> Color {
        switch seat {
        case .yours:     return Theme.Palette.accent.opacity(0.14)
        case .claimed:   return Theme.Palette.surface
        case .available: return Theme.Palette.surface.opacity(0.5)
        }
    }

    private func border(for seat: Seat) -> Color {
        switch seat {
        case .yours:     return Theme.Palette.accent
        case .claimed:   return Theme.Palette.hairline
        case .available: return Theme.Palette.hairline.opacity(0.6)
        }
    }

    private func borderWidth(for seat: Seat) -> CGFloat {
        seat == .yours ? 1.0 : 0.5
    }

    private func initial(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "·" }
        return String(first).uppercased()
    }

    // MARK: A11y

    private func accessibilityLabel(for seat: Seat, at index: Int) -> String {
        let position = "Seat \(index + 1)"
        switch seat {
        case .yours:               return "\(position), your seat"
        case .claimed(let name):   return "\(position), claimed by \(name)"
        case .available:           return "\(position), open"
        }
    }
}

#if DEBUG
#Preview("Seat grid, 8 seats") {
    SeatGridView(
        seats: [
            .yours,
            .claimed(name: "Thea"),
            .claimed(name: "Marco"),
            .available,
            .claimed(name: "Priya"),
            .available,
            .claimed(name: "Jules"),
            .claimed(name: "Ren"),
        ],
        columns: 4,
        onTapSeat: { _ in }
    )
    .padding()
    .background(Theme.Palette.background)
    .preferredColorScheme(.dark)
}

#Preview("Seat grid, 4 seats") {
    SeatGridView(
        seats: [
            .yours,
            .claimed(name: "Thea"),
            .claimed(name: "Marco"),
            .available,
        ],
        columns: 4
    )
    .padding()
    .background(Theme.Palette.background)
    .preferredColorScheme(.dark)
}
#endif