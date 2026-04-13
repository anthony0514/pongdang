import SwiftUI
import FirebaseFirestore
import UIKit

struct ManageSpaceView: View {
    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    let space: Space

    @State private var spaceName: String
    @State private var savedSpaceName: String
    @State private var members: [MemberInfo] = []
    @State private var inviteCode = ""
    @State private var isLoading = false
    @State private var localErrorMessage: String?
    @State private var isSavingName = false
    @State private var didSaveName = false
    @State private var showingLeaveAlert = false

    init(space: Space) {
        self.space = space
        _spaceName = State(initialValue: space.name)
        _savedSpaceName = State(initialValue: space.name)
    }

    private var currentSpace: Space {
        spaceService.spaces.first(where: { $0.id == space.id }) ?? space
    }

    var body: some View {
        NavigationStack {
            Form {
                if let localErrorMessage, !localErrorMessage.isEmpty {
                    Section {
                        Text(localErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("기본 정보") {
                    HStack(spacing: 12) {
                        TextField("스페이스 이름", text: $spaceName)
                            .disabled(!isOwner)
                            .onChange(of: spaceName) { _, _ in
                                spaceName = InputSanitizer.sanitize(spaceName, as: .spaceName)
                                didSaveName = false
                            }

                        Button {
                            saveSpaceName()
                        } label: {
                            Text(saveButtonTitle)
                                .font(.subheadline.weight(.semibold))
                                .frame(minWidth: 84)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(saveButtonTint)
                        .disabled(!isOwner || !hasPendingNameChange || isSavingName)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                    Button(isFavoriteSpace ? "즐겨찾기된 스페이스" : "즐겨찾기로 설정") {
                        spaceService.setFavoriteSpace(currentSpace)
                    }
                    .disabled(isFavoriteSpace)
                }

                Section("초대 코드") {
                    if isOwner {
                        if inviteCode.isEmpty {
                            Text("생성된 초대 코드가 없습니다. 필요할 때 직접 생성해 주세요.")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(inviteCode)
                                        .font(.system(.title3, design: .rounded, weight: .bold))
                                    Spacer()
                                    Button("복사") {
                                        UIPasteboard.general.string = inviteCode
                                    }
                                }

                                Text("생성 후 10분 동안만 유효합니다.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button(inviteCode.isEmpty ? "초대 코드 생성" : "초대 코드 재생성") {
                            regenerateInviteCode()
                        }
                    } else {
                        Text("초대 코드는 방장만 확인하고 재생성할 수 있습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("멤버 \(members.count)명") {
                    ForEach(members) { member in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(member.name)
                                Text(member.id == currentSpace.createdBy ? "생성자" : "멤버")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if member.id == authService.currentUser?.id {
                                Text("나")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if isOwner && members.count > 1 && member.id != currentSpace.createdBy {
                                Button("제거", role: .destructive) {
                                    removeMember(member)
                                }
                            }
                        }
                    }
                }

                Section("주의") {
                    if isOwner {
                        Text("스페이스 삭제 시 장소와 방문 기록도 함께 삭제됩니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button("스페이스 삭제", role: .destructive) {
                            deleteSpace()
                        }
                    } else {
                        Text("탈퇴하면 이 스페이스의 장소와 기록 열람이 즉시 중단됩니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button("스페이스 탈퇴", role: .destructive) {
                            showingLeaveAlert = true
                        }
                    }
                }
            }
            .navigationTitle("스페이스 관리")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                syncNameFromCurrentSpace()
            }
            .onChange(of: currentSpace.name) { _, _ in
                syncNameFromCurrentSpace()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") {
                        dismiss()
                    }
                }
            }
            .alert("스페이스를 탈퇴할까요?", isPresented: $showingLeaveAlert) {
                Button("탈퇴", role: .destructive) {
                    leaveSpace()
                }
                Button("취소", role: .cancel) {
                }
            } message: {
                Text("탈퇴 후에는 초대 코드를 다시 입력해야 다시 참여할 수 있습니다.")
            }
            .task(id: currentSpace.id) {
                await loadInitialData()
            }
            .task(id: currentSpace.memberIDs.joined(separator: "|")) {
                await loadInitialData()
            }
            .overlay {
                if isLoading {
                    ZStack {
                        Color.black.opacity(0.12)
                            .ignoresSafeArea()
                        ProgressView()
                            .padding(20)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }

    private var trimmedSpaceName: String {
        spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isFavoriteSpace: Bool {
        spaceService.isFavoriteSpace(currentSpace)
    }

    private var isOwner: Bool {
        authService.currentUser?.id == currentSpace.createdBy
    }

    private var hasPendingNameChange: Bool {
        !trimmedSpaceName.isEmpty && trimmedSpaceName != savedSpaceName
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

    private func loadInitialData() async {
        isLoading = true
        await loadInviteCode()
        await loadMembers()
        isLoading = false
    }

    private func loadInviteCode() async {
        guard isOwner else {
            inviteCode = ""
            return
        }

        do {
            inviteCode = try await spaceService.fetchValidInviteCode(
                for: currentSpace.id,
                requestedBy: authService.currentUser?.id ?? ""
            ) ?? ""
        } catch {
            presentError(error)
        }
    }

    private func regenerateInviteCode() {
        Task {
            isLoading = true
            localErrorMessage = nil
            do {
                inviteCode = try await spaceService.generateInviteCode(
                    for: currentSpace.id,
                    createdBy: authService.currentUser?.id ?? currentSpace.createdBy
                )
            } catch {
                presentError(error)
            }
            isLoading = false
        }
    }

    private func loadMembers() async {
        let memberIDs = currentSpace.memberIDs

        do {
            let snapshots = try await Firestore.firestore()
                .collection("users")
                .whereField(FieldPath.documentID(), in: memberIDs)
                .getDocuments()

            let usersByID: [String: String] = Dictionary(uniqueKeysWithValues: snapshots.documents.map { document in
                let documentID = document.documentID
                let fallbackName = documentID == "guest-user" ? "익명" : "알 수 없음"
                return (
                    documentID,
                    document.data()["name"] as? String ?? fallbackName
                )
            })

            members = memberIDs.map { memberID in
                MemberInfo(
                    id: memberID,
                    name: usersByID[memberID] ?? (memberID == "guest-user" ? "익명" : "알 수 없음")
                )
            }
        } catch {
            members = memberIDs.map {
                MemberInfo(id: $0, name: $0 == "guest-user" ? "익명" : "알 수 없음")
            }
            presentError(error)
        }
    }

    private func saveSpaceName() {
        Task {
            isSavingName = true
            didSaveName = false
            localErrorMessage = nil
            let sanitizedName = InputSanitizer.sanitize(trimmedSpaceName, as: .spaceName)

            do {
                try await spaceService.updateSpaceName(
                    spaceID: currentSpace.id,
                    name: sanitizedName,
                    requestedBy: authService.currentUser?.id ?? ""
                )
                savedSpaceName = sanitizedName
                spaceName = sanitizedName
                didSaveName = true
            } catch {
                presentError(error)
            }
            isSavingName = false
        }
    }

    private func removeMember(_ member: MemberInfo) {
        Task {
            isLoading = true
            localErrorMessage = nil
            do {
                try await spaceService.removeMember(
                    spaceID: currentSpace.id,
                    userID: member.id,
                    requestedBy: authService.currentUser?.id ?? ""
                )

                if member.id == authService.currentUser?.id {
                    dismiss()
                } else {
                    await loadMembers()
                }
            } catch {
                presentError(error)
            }
            isLoading = false
        }
    }

    private func deleteSpace() {
        Task {
            isLoading = true
            localErrorMessage = nil
            do {
                try await spaceService.deleteSpace(
                    spaceID: currentSpace.id,
                    requestedBy: authService.currentUser?.id ?? ""
                )
                dismiss()
            } catch {
                presentError(error)
            }
            isLoading = false
        }
    }

    private func leaveSpace() {
        Task {
            isLoading = true
            localErrorMessage = nil
            do {
                try await spaceService.leaveSpace(
                    spaceID: currentSpace.id,
                    userID: authService.currentUser?.id ?? ""
                )
                dismiss()
            } catch {
                presentError(error)
            }
            isLoading = false
        }
    }

    private func presentError(_ error: Error) {
        let message = error.localizedDescription
        spaceService.errorMessage = message
        localErrorMessage = message
    }

    private func syncNameFromCurrentSpace() {
        let currentName = currentSpace.name

        if !hasPendingNameChange || spaceName == savedSpaceName {
            spaceName = currentName
        }

        savedSpaceName = currentName
    }
}

private struct MemberInfo: Identifiable, Equatable {
    let id: String
    let name: String
}
