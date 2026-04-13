import SwiftUI

struct SettingsView: View {
    private enum ExternalMapApp: String, CaseIterable, Identifiable {
        case apple
        case kakao
        case naver

        var id: String { rawValue }

        var title: String {
            switch self {
            case .apple:
                return "지도"
            case .kakao:
                return "카카오맵"
            case .naver:
                return "네이버지도"
            }
        }
    }
    
    @EnvironmentObject var authService: AuthService
    @State private var draftName = ""
    @State private var savedUserName = ""
    @State private var isSavingName = false
    @State private var didSaveName = false
    @State private var showingLogoutDialog = false
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
                        .disabled(authService.isGuestUser)
                        .onChange(of: draftName) { _, _ in
                            draftName = InputSanitizer.sanitize(draftName, as: .displayName)
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
                    .disabled(authService.isGuestUser || !hasPendingNameChange || isSavingName)
                }

                if authService.isGuestUser {
                    Text("게스트 모드에서는 이름을 변경할 수 없습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("앱 설정") {
                Picker("기본 지도 앱", selection: $preferredExternalMapAppRawValue) {
                    ForEach(ExternalMapApp.allCases) { app in
                        Text(app.title).tag(app.rawValue)
                    }
                }

                Toggle(isOn: $localNotificationsEnabled) {
                    Text("스페이스 알림")
                        .foregroundStyle(.primary.opacity(localNotificationsEnabled ? 1 : 0.5))
                }

                VStack(alignment: .leading, spacing: 24) {
                    Toggle(isOn: newMemberNotificationBinding) {
                        Text("새 멤버 참가")
                            .foregroundStyle(.primary.opacity(newMemberLabelOpacity))
                    }

                    Toggle(isOn: newPlaceNotificationBinding) {
                        Text("새 장소 등록")
                            .foregroundStyle(.primary.opacity(newPlaceLabelOpacity))
                    }

                    Toggle(isOn: newMemoNotificationBinding) {
                        Text("새 메모 작성")
                            .foregroundStyle(.primary.opacity(newMemoLabelOpacity))
                    }
                }
                .padding(.leading, 18)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .disabled(notificationChildrenDisabled)
                .opacity(notificationChildrenDisabled ? 0.55 : 1)

                if authService.isGuestUser {
                    Text("게스트 모드에서는 멤버 알림 수신 설정을 저장할 수 없습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("계정") {
                Button("로그아웃", role: .destructive) {
                    showingLogoutDialog = true
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            Section {
                AppSheetFooter()
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
        .confirmationDialog("계정 작업", isPresented: $showingLogoutDialog, titleVisibility: .visible) {
            Button("로그아웃", role: .destructive) {
                authService.signOut()
            }
            if !authService.isGuestUser {
                Button("계정 삭제", role: .destructive) {
                    showingDeleteAccountAlert = true
                }
            }
            Button("취소", role: .cancel) {}
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
        let sanitizedName = InputSanitizer.sanitize(trimmedDraftName, as: .displayName)
        
        Task {
            isSavingName = true
            didSaveName = false
            localErrorMessage = nil
            do {
                try await authService.updateDisplayName(userID: userID, name: sanitizedName)
                savedUserName = sanitizedName
                draftName = sanitizedName
                didSaveName = true
            } catch {
                localErrorMessage = error.localizedDescription
            }
            isSavingName = false
        }
    }
    
    private func handleNotificationToggleChange(_ isEnabled: Bool) {
        if !isEnabled {
            updateMemberNotificationPreference(newMember: false, newPlace: false, newMemo: false)
            return
        }

        updateMemberNotificationPreference(newMember: true, newPlace: true, newMemo: true)

        Task {
            let granted = await LocalNotificationManager.requestAuthorizationIfNeeded()
            guard !granted else { return }
            
            await MainActor.run {
                localNotificationsEnabled = false
                localErrorMessage = "알림 권한이 없습니다. iPhone 설정에서 알림을 허용해 주세요."
            }
        }
    }

    private var notificationChildrenDisabled: Bool {
        !localNotificationsEnabled || authService.isGuestUser || authService.currentUser == nil
    }

    private var newMemberLabelOpacity: Double {
        guard !notificationChildrenDisabled else { return 0.5 }
        return (authService.currentUser?.receivesNewMemberNotifications ?? true) ? 1 : 0.5
    }

    private var newPlaceLabelOpacity: Double {
        guard !notificationChildrenDisabled else { return 0.5 }
        return (authService.currentUser?.receivesNewPlaceNotifications ?? true) ? 1 : 0.5
    }

    private var newMemoLabelOpacity: Double {
        guard !notificationChildrenDisabled else { return 0.5 }
        return (authService.currentUser?.receivesNewMemoNotifications ?? true) ? 1 : 0.5
    }

    private var newMemberNotificationBinding: Binding<Bool> {
        Binding(
            get: { authService.currentUser?.receivesNewMemberNotifications ?? true },
            set: { newValue in
                updateMemberNotificationPreference(
                    newMember: newValue,
                    newPlace: authService.currentUser?.receivesNewPlaceNotifications ?? true,
                    newMemo: authService.currentUser?.receivesNewMemoNotifications ?? true
                )
            }
        )
    }

    private var newPlaceNotificationBinding: Binding<Bool> {
        Binding(
            get: { authService.currentUser?.receivesNewPlaceNotifications ?? true },
            set: { newValue in
                updateMemberNotificationPreference(
                    newMember: authService.currentUser?.receivesNewMemberNotifications ?? true,
                    newPlace: newValue,
                    newMemo: authService.currentUser?.receivesNewMemoNotifications ?? true
                )
            }
        )
    }

    private var newMemoNotificationBinding: Binding<Bool> {
        Binding(
            get: { authService.currentUser?.receivesNewMemoNotifications ?? true },
            set: { newValue in
                updateMemberNotificationPreference(
                    newMember: authService.currentUser?.receivesNewMemberNotifications ?? true,
                    newPlace: authService.currentUser?.receivesNewPlaceNotifications ?? true,
                    newMemo: newValue
                )
            }
        )
    }

    private func updateMemberNotificationPreference(newMember: Bool, newPlace: Bool, newMemo: Bool) {
        Task {
            localErrorMessage = nil

            do {
                try await authService.updateNotificationPreferences(newMember: newMember, newPlace: newPlace, newMemo: newMemo)
            } catch {
                localErrorMessage = error.localizedDescription
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
