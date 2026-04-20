import SwiftUI

struct SpaceListView: View {
    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var showingCreate = false
    @State private var showingInvite = false
    @State private var managingSpace: Space?
    @State private var joinCode = ""
    @State private var joinToastMessage: String?
    @State private var isJoining = false

    var body: some View {
        List {
            if spaceService.spaces.isEmpty {
                ContentUnavailableView(
                    "참여한 스페이스가 없습니다",
                    systemImage: "person.3",
                    description: Text("스페이스를 만들거나 초대 코드로 참여해 보세요.")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(spaceService.spaces) { space in
                    SpaceRow(
                        space: space,
                        isActive: space.id == spaceService.activeSpace?.id,
                        isFavorite: spaceService.isFavoriteSpace(space),
                        onManage: {
                            managingSpace = space
                        },
                        onSelect: {
                            spaceService.setActiveSpace(space)
                            dismiss()
                        }
                    )
                }
            }
        }
        .navigationTitle("스페이스")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !authService.isGuestUser {
                        Button {
                            showingCreate = true
                        } label: {
                            Label("생성", systemImage: "plus.circle")
                        }
                    }

                    Button {
                        spaceService.errorMessage = nil
                        joinCode = ""
                        showingInvite = true
                    } label: {
                        Label("참여", systemImage: "person.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingInvite) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("스페이스 참여")
                        .font(.headline)
                    Text("초대 코드를 입력하세요. 코드는 10분 후 만료됩니다.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                TextField("6자리 코드 입력", text: $joinCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onChange(of: joinCode) { _, newValue in
                        joinCode = InputSanitizer.sanitize(newValue.uppercased(), as: .inviteCode)
                    }

                VStack(spacing: 10) {
                    Button("참여하기") {
                        joinSpace()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(isJoining)

                    Button("취소", role: .cancel) {
                        showingInvite = false
                        joinCode = ""
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(isJoining)
                }
            }
            .padding(24)
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingCreate) {
            CreateSpaceView()
                .environmentObject(spaceService)
                .environmentObject(authService)
        }
        .sheet(item: $managingSpace) { space in
            ManageSpaceView(space: space)
                .environmentObject(spaceService)
                .environmentObject(authService)
        }
        .overlay(alignment: .bottom) {
            if let joinToastMessage {
                Text(joinToastMessage)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: joinToastMessage != nil)
    }

    private func joinSpace() {
        Task {
            isJoining = true

            let normalizedCode = InputSanitizer
                .sanitize(joinCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), as: .inviteCode)

            guard !normalizedCode.isEmpty else {
                showingInvite = false
                joinCode = ""
                isJoining = false
                showJoinToast("초대 코드를 입력해 주세요.")
                return
            }

            do {
                let result = try await spaceService.joinSpace(
                    with: normalizedCode,
                    userID: authService.currentUser!.id
                )
                showingInvite = false
                joinCode = ""
                showJoinToast(
                    result == .joined
                    ? "스페이스에 참여했습니다."
                    : "이미 참여 중인 스페이스입니다."
                )
            } catch {
                showingInvite = false
                joinCode = ""
                showJoinToast("참여에 실패했습니다.")
            }

            isJoining = false
        }
    }

    private func showJoinToast(_ message: String) {
        joinToastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            await MainActor.run {
                if joinToastMessage == message {
                    joinToastMessage = nil
                }
            }
        }
    }
}

private struct SpaceRow: View {
    let space: Space
    let isActive: Bool
    let isFavorite: Bool
    let onManage: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack {
            Button(action: onSelect) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if isFavorite {
                                Image(systemName: "star.fill")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color(hex: "F4B400"))
                            }

                            Text(space.name)
                        }

                        Text("멤버 \(space.memberIDs.count)명")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if isActive {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onManage) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}
