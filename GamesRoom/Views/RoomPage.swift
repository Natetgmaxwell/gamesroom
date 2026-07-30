import SwiftUI

struct RoomPage: View {
    @Binding var activeRoom: Room?
    @EnvironmentObject private var homeVM: HomeViewModel
    @EnvironmentObject private var roomService: RoomService
    @EnvironmentObject private var authService: AuthService
    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage("lastViewedRoomId") private var lastViewedRoomIdString: String = ""
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var showGenerateCode = false
    @State private var inviteRoomId: UUID?

    var body: some View {
        Group {
            if let room = resolvedRoom {
                RoomDetailView(
                    room: room,
                    allRooms: homeVM.rooms,
                    onDismiss: { activeRoom = nil },
                    onSwitchRoom: { r in
                        activeRoom = r
                        homeVM.markViewed(r)
                    }
                )
            } else if !homeVM.rooms.isEmpty {
                roomsListState
            } else {
                emptyState
            }
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private var resolvedRoom: Room? {
        if let room = activeRoom { return room }
        if let id = UUID(uuidString: lastViewedRoomIdString),
           let room = homeVM.rooms.first(where: { $0.id == id }) {
            return room
        }
        return nil
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 16) {
                Text("No rooms yet")
                    .font(Theme.displayFont)
                    .foregroundStyle(Theme.primaryText)
                    .multilineTextAlignment(.center)

                if let err = roomService.lastError {
                    Text(err)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.red.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 8)
                }

                Button {
                    showCreate = true
                } label: {
                    Text("Create one to get started.")
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.accent)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .buttonStyle(.plain)

                Button {
                    showJoin = true
                } label: {
                    Text("Join with a code")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
                .buttonStyle(.plain)

                Button {
                    Task { await refresh() }
                } label: {
                    Text("Try again")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 16)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: hSize == .regular ? 500 : .infinity)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 24)
        .sheet(isPresented: $showCreate) {
            CreateRoomView(onCreated: {
                showCreate = false
                await refresh()
            })
            .environmentObject(roomService)
        }
        .sheet(isPresented: $showJoin) {
            JoinCodeView { code in
                do {
                    let result = try await roomService.redeemJoinCode(code)
                    homeVM.setWelcome(result.roomName)
                    await refresh()
                    return .success(roomName: result.roomName)
                } catch {
                    return .failure(error.localizedDescription)
                }
            }
        }
    }

    private var roomsListState: some View {
        ScrollView {
            if hSize == .regular {
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Your rooms")
                            .font(Theme.displayFont)
                            .foregroundStyle(Theme.primaryText)
                        Spacer()
                        Button { showCreate = true } label: {
                            Text("New")
                                .font(.system(size: 15, weight: .regular))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 24)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                        ForEach(homeVM.rooms) { room in
                            HeroCard(room: room, onGetCode: {
                                inviteRoomId = room.id
                                showGenerateCode = true
                            }, onTap: {
                                homeVM.markViewed(room)
                            })
                        }
                    }
                    .padding(.horizontal, 32)
                }
                .padding(.bottom, 24)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Your rooms")
                            .font(Theme.displayFont)
                            .foregroundStyle(Theme.primaryText)
                        Spacer()
                        Button { showCreate = true } label: {
                            Text("New")
                                .font(.system(size: 15, weight: .regular))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 24)

                    ForEach(homeVM.rooms) { room in
                        HStack(spacing: 12) {
                            RoomRow(room: room) {
                                homeVM.markViewed(room)
                            }
                            if let currentUser = authService.currentUser,
                               room.createdBy == currentUser.id {
                                Button {
                                    inviteRoomId = room.id
                                    showGenerateCode = true
                                } label: {
                                    Text("Invite a friend")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 32)
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .refreshable { await refresh() }
        .sheet(isPresented: $showGenerateCode) {
            if let id = inviteRoomId {
                GenerateCodeView(roomId: id) {
                    showGenerateCode = false
                    inviteRoomId = nil
                }
                .environmentObject(roomService)
            }
        }
    }

    private func refresh() async {
        await roomService.refresh()
        homeVM.update(rooms: roomService.rooms)
    }
}
