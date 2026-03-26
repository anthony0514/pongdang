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

    init(space: Space) {
        self.space = space
        _spaceName = State(initialValue: space.name)
        _savedSpaceName = State(initialValue: space.name)
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
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("스페이스 이름", text: $spaceName)
                            .onChange(of: spaceName) { _, _ in
                                didSaveName = false
                            }

                        HStack {
                            Text(hasPendingNameChange ? "이름이 변경되었습니다." : "현재 이름이 저장된 상태입니다.")
                                .font(.caption)
                                .foregroundStyle(hasPendingNameChange ? .secondary : Color.green)

                            Spacer()

                            Button {
                                saveSpaceName()
                            } label: {
                                Text(saveButtonTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(minWidth: 84)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(saveButtonTint)
                            .disabled(!hasPendingNameChange || isSavingName)
                        }
                    }

                    Button(isActiveSpace ? "현재 선택된 스페이스" : "현재 스페이스로 선택") {
                        spaceService.setActiveSpace(space)
                    }
                    .disabled(isActiveSpace)
                }

                Section("초대 코드") {
                    if inviteCode.isEmpty {
                        Text("유효한 초대 코드를 불러오는 중입니다.")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text(inviteCode)
                                .font(.system(.title3, design: .rounded, weight: .bold))
                            Spacer()
                            Button("복사") {
                                UIPasteboard.general.string = inviteCode
                            }
                        }
                    }

                    Button("초대 코드 재생성") {
                        regenerateInviteCode()
                    }
                }

                Section("멤버 \(members.count)명") {
                    ForEach(members) { member in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(member.name)
                                Text(member.id == space.createdBy ? "생성자" : "멤버")
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
                            if members.count > 1 {
                                Button("제거", role: .destructive) {
                                    removeMember(member)
                                }
                            }
                        }
                    }
                }

                Section("주의") {
                    Text("스페이스 삭제 시 장소와 방문 기록도 함께 삭제됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("스페이스 삭제", role: .destructive) {
                        deleteSpace()
                    }
                }
            }
            .navigationTitle("스페이스 관리")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") {
                        dismiss()
                    }
                }
            }
            .task(id: space.id) {
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

    private var isActiveSpace: Bool {
        spaceService.activeSpace?.id == space.id
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

        return "이름 저장"
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
        do {
            if let code = try await spaceService.fetchValidInviteCode(for: space.id) {
                inviteCode = code
            } else {
                inviteCode = try await spaceService.generateInviteCode(
                    for: space.id,
                    createdBy: authService.currentUser?.id ?? space.createdBy
                )
            }
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
                    for: space.id,
                    createdBy: authService.currentUser?.id ?? space.createdBy
                )
            } catch {
                presentError(error)
            }
            isLoading = false
        }
    }

    private func loadMembers() async {
        do {
            let snapshots = try await Firestore.firestore()
                .collection("users")
                .whereField(FieldPath.documentID(), in: space.memberIDs)
                .getDocuments()

            let usersByID = Dictionary(uniqueKeysWithValues: snapshots.documents.map { document in
                (
                    document.documentID,
                    document.data()["name"] as? String ?? "알 수 없음"
                )
            })

            members = space.memberIDs.map { memberID in
                MemberInfo(
                    id: memberID,
                    name: usersByID[memberID] ?? "알 수 없음"
                )
            }
        } catch {
            members = space.memberIDs.map { MemberInfo(id: $0, name: "알 수 없음") }
            presentError(error)
        }
    }

    private func saveSpaceName() {
        Task {
            isSavingName = true
            didSaveName = false
            localErrorMessage = nil
            do {
                try await spaceService.updateSpaceName(spaceID: space.id, name: trimmedSpaceName)
                savedSpaceName = trimmedSpaceName
                spaceName = trimmedSpaceName
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
                try await spaceService.removeMember(spaceID: space.id, userID: member.id)

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
                try await spaceService.deleteSpace(spaceID: space.id)
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
}

private struct MemberInfo: Identifiable, Equatable {
    let id: String
    let name: String
}
