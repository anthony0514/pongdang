import SwiftUI

struct SettingsView: View {
    private enum ExternalMapApp: String, CaseIterable, Identifiable {
        case kakao
        case naver

        var id: String { rawValue }

        var title: String {
            switch self {
            case .kakao:
                return "카카오맵"
            case .naver:
                return "네이버지도"
            }
        }
    }

    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var spaceService: SpaceService

    @State private var showingHomeSettings = false
    @State private var draftName = ""
    @State private var savedUserName = ""
    @State private var isSavingName = false
    @State private var didSaveName = false
    @State private var localErrorMessage: String?
    @AppStorage("preferredExternalMapApp") private var preferredExternalMapAppRawValue = ExternalMapApp.kakao.rawValue

    var body: some View {
        Form {
            if let localErrorMessage, !localErrorMessage.isEmpty {
                Section {
                    Text(localErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("내 정보") {
                HStack(spacing: 12) {
                    TextField("이름", text: $draftName)
                        .onChange(of: draftName) { _, _ in
                            didSaveName = false
                        }

                    Button {
                        saveName()
                    } label: {
                        Text(saveButtonTitle)
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 84)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(saveButtonTint)
                    .disabled(!hasPendingNameChange || isSavingName)
                }

                if let homeSummary {
                    Text(homeSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            Section("지도 앱") {
                Picker("기본 지도 앱", selection: $preferredExternalMapAppRawValue) {
                    ForEach(ExternalMapApp.allCases) { app in
                        Text(app.title).tag(app.rawValue)
                    }
                }
                .pickerStyle(.inline)
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
        .onAppear {
            syncNameFromCurrentUser()
        }
        .onChange(of: authService.currentUser?.name) { _, _ in
            syncNameFromCurrentUser()
        }
    }

    private var homeSummary: String? {
        if let address = authService.currentUser?.homeAddress, !address.isEmpty {
            return address
        }
        return nil
    }

    private var trimmedDraftName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasPendingNameChange: Bool {
        !trimmedDraftName.isEmpty && trimmedDraftName != savedUserName
    }

    private var saveButtonTitle: String {
        if isSavingName {
            return "저장 중"
        }

        if didSaveName && !hasPendingNameChange {
            return "저장됨"
        }

        return "저장"
    }

    private var saveButtonTint: Color {
        if didSaveName && !hasPendingNameChange {
            return .green
        }

        return .accentColor
    }

    private func syncNameFromCurrentUser() {
        let currentName = authService.currentUser?.name ?? ""
        savedUserName = currentName
        if draftName.isEmpty || draftName == savedUserName {
            draftName = currentName
        }
    }

    private func saveName() {
        guard !trimmedDraftName.isEmpty, let userID = authService.currentUser?.id else { return }

        Task {
            isSavingName = true
            didSaveName = false
            localErrorMessage = nil
            do {
                try await authService.updateDisplayName(userID: userID, name: trimmedDraftName)
                savedUserName = trimmedDraftName
                draftName = trimmedDraftName
                didSaveName = true
            } catch {
                localErrorMessage = error.localizedDescription
            }
            isSavingName = false
        }
    }
}
