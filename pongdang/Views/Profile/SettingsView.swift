import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var spaceService: SpaceService

    @State private var showingHomeSettings = false
    @State private var showingEditName = false
    @State private var draftName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("내 정보") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(authService.currentUser?.name ?? "사용자")
                                .font(.headline)

                            if let homeSummary {
                                Text(homeSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Button("이름 수정") {
                            draftName = authService.currentUser?.name ?? ""
                            showingEditName = true
                        }
                    }
                }

                Section("위치 설정") {
                    Button("내 집 위치 설정") {
                        showingHomeSettings = true
                    }

                    if let activeSpace = spaceService.activeSpace {
                        HStack {
                            Text("현재 스페이스")
                            Spacer()
                            Text(activeSpace.name)
                                .foregroundStyle(.secondary)
                        }

                        if let userID = authService.currentUser?.id {
                            HStack {
                                Text("내 집 위치 공개")
                                Spacer()
                                Text(activeSpace.sharedHomeMemberIDs.contains(userID) ? "공개 중" : "비공개")
                                    .foregroundStyle(activeSpace.sharedHomeMemberIDs.contains(userID) ? Color.green : .secondary)
                            }
                        }
                    } else {
                        Text("활성 스페이스가 없습니다.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("계정") {
                    Button("로그아웃", role: .destructive) {
                        authService.signOut()
                    }
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingHomeSettings) {
                HomeLocationSettingsView()
                    .environmentObject(authService)
                    .environmentObject(spaceService)
            }
            .alert("이름 수정", isPresented: $showingEditName) {
                TextField("이름", text: $draftName)
                Button("취소", role: .cancel) {
                }
                Button("저장") {
                    saveName()
                }
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("내 정보에 표시될 이름을 변경합니다.")
            }
        }
    }

    private var homeSummary: String? {
        if let address = authService.currentUser?.homeAddress, !address.isEmpty {
            return address
        }
        return nil
    }

    private func saveName() {
        let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let userID = authService.currentUser?.id else { return }

        Task {
            do {
                try await authService.updateDisplayName(userID: userID, name: trimmedName)
            } catch {
                authService.errorMessage = error.localizedDescription
            }
        }
    }
}
