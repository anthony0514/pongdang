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
    @Environment(\.openURL) private var openURL

    @State private var draftName = ""
    @State private var savedUserName = ""
    @State private var isSavingName = false
    @State private var didSaveName = false
    @State private var showingDeleteAccountAlert = false
    @State private var localErrorMessage: String?
    @AppStorage("preferredExternalMapApp") private var preferredExternalMapAppRawValue = ExternalMapApp.kakao.rawValue
    @AppStorage(AppPreferences.localNotificationsEnabledKey) private var localNotificationsEnabled = true

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

                if authService.isGuestUser {
                    Text("게스트 모드에서는 로컬로만 이름이 저장됩니다.")
                        .font(.caption)
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

            Section("알림") {
                Toggle("앱 알림", isOn: $localNotificationsEnabled)

                Text("메모 추가와 방문 기록 저장 알림을 앱에서 받을 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                AppSheetFooter()
            }

            Section("계정") {
                Button("로그아웃", role: .destructive) {
                    authService.signOut()
                }

                if !authService.isGuestUser {
                    Button("계정 삭제", role: .destructive) {
                        showingDeleteAccountAlert = true
                    }
                    .disabled(authService.isLoading)
                }
            }
        }
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            syncNameFromCurrentUser()
        }
        .onChange(of: authService.currentUser?.name) { _, _ in
            syncNameFromCurrentUser()
        }
        .onChange(of: localNotificationsEnabled) { _, newValue in
            handleNotificationToggleChange(newValue)
        }
        .alert("계정을 삭제할까요?", isPresented: $showingDeleteAccountAlert) {
            Button("삭제", role: .destructive) {
                deleteAccount()
            }
            Button("취소", role: .cancel) {
            }
        } message: {
            Text("계정과 내가 만든 장소 및 기록이 삭제되며 되돌릴 수 없습니다.")
        }
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

    private func handleNotificationToggleChange(_ isEnabled: Bool) {
        guard isEnabled else { return }

        Task {
            let granted = await LocalNotificationManager.requestAuthorizationIfNeeded()
            guard !granted else { return }

            await MainActor.run {
                localNotificationsEnabled = false
                localErrorMessage = "알림 권한이 없습니다. iPhone 설정에서 알림을 허용해 주세요."
            }
        }
    }

    private func deleteAccount() {
        Task {
            localErrorMessage = nil

            do {
                try await authService.deleteCurrentAccount()
            } catch {
                localErrorMessage = error.localizedDescription
            }
        }
    }

}
