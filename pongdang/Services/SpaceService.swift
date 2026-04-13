import Foundation
import Combine
import FirebaseFirestore

@MainActor
final class SpaceService: ObservableObject {
    enum JoinResult: Equatable {
        case joined
        case alreadyMember
    }

    private static let guestUserID = "guest-user"

    @Published var spaces: [Space] = []
    @Published var activeSpace: Space?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private var listener: ListenerRegistration?
    private let db = Firestore.firestore()
    private var currentUserID: String?

    deinit {
        listener?.remove()
    }

    func fetchSpaces(for userID: String) {
        listener?.remove()
        isLoading = true
        errorMessage = nil
        currentUserID = userID

        listener = db.collection("spaces")
            .whereField("memberIDs", arrayContains: userID)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }

                if let error {
                    Task { @MainActor in
                        self.errorMessage = error.localizedDescription
                        self.isLoading = false
                    }
                    return
                }

                let spaces = snapshot?.documents.compactMap { document -> Space? in
                    self.makeSpace(from: document)
                }
                .sorted { $0.createdAt < $1.createdAt } ?? []

                Task { @MainActor in
                    self.spaces = spaces
                    if let activeSpace = self.activeSpace,
                       let updatedActiveSpace = spaces.first(where: { $0.id == activeSpace.id }) {
                        self.activeSpace = updatedActiveSpace
                    } else if self.activeSpace == nil || !spaces.contains(where: { $0.id == self.activeSpace?.id }) {
                        self.activeSpace = spaces.first
                    }
                    self.errorMessage = nil
                    self.isLoading = false
                }
            }
    }

    func setActiveSpace(_ space: Space) {
        activeSpace = space
    }

    func createSpace(name: String, createdBy: String) async throws -> Space {
        guard createdBy != Self.guestUserID else {
            throw Self.makeError("게스트 모드에서는 스페이스를 만들 수 없습니다")
        }

        let ref = db.collection("spaces").document()
        let space = Space(
            id: ref.documentID,
            name: name,
            memberIDs: [createdBy],
            sharedHomeMemberIDs: [],
            createdAt: Date(),
            createdBy: createdBy
        )

        try await ref.setData([
            "name": space.name,
            "memberIDs": space.memberIDs,
            "sharedHomeMemberIDs": space.sharedHomeMemberIDs,
            "createdAt": Timestamp(date: space.createdAt),
            "createdBy": space.createdBy
        ])

        upsertLocalSpace(space)
        activeSpace = space

        return space
    }

    func generateInviteCode(for spaceID: String, createdBy: String) async throws -> String {
        try await ensureOwner(spaceID: spaceID, requesterID: createdBy, failureMessage: "방장만 초대 코드를 생성할 수 있습니다")

        let existingCodes = try await db.collection("inviteCodes")
            .whereField("spaceID", isEqualTo: spaceID)
            .getDocuments()

        for document in existingCodes.documents {
            try await document.reference.delete()
        }

        let code = try await makeUniqueInviteCode()
        let createdAt = Date()
        let expiresAt = createdAt.addingTimeInterval(10 * 60)

        try await db.collection("inviteCodes").document(code).setData([
            "spaceID": spaceID,
            "createdBy": createdBy,
            "createdAt": Timestamp(date: createdAt),
            "expiresAt": Timestamp(date: expiresAt)
        ])

        return code
    }

    func joinSpace(with code: String, userID: String) async throws -> JoinResult {
        let normalizedCode = code.uppercased()
        let snapshot = try await db.collection("inviteCodes").document(normalizedCode).getDocument()

        guard
            snapshot.exists,
            let data = snapshot.data()
        else {
            throw Self.makeError("유효하지 않은 코드입니다")
        }

        guard let expiresAt = data["expiresAt"] as? Timestamp else {
            throw Self.makeError("유효하지 않은 코드입니다")
        }

        guard expiresAt.dateValue() >= Date() else {
            throw Self.makeError("만료된 코드입니다")
        }

        guard let spaceID = data["spaceID"] as? String, !spaceID.isEmpty else {
            throw Self.makeError("유효하지 않은 코드입니다")
        }

        if let existingSpace = try await fetchSpace(id: spaceID),
           existingSpace.memberIDs.contains(userID) {
            try await refreshSpaces()
            activeSpace = spaces.first(where: { $0.id == spaceID }) ?? existingSpace
            return .alreadyMember
        }

        do {
            try await db.collection("spaces").document(spaceID).updateData([
                "memberIDs": FieldValue.arrayUnion([userID])
            ])
            try await refreshSpaces()
            activeSpace = spaces.first(where: { $0.id == spaceID }) ?? activeSpace
            return .joined
        } catch {
            let nsError = error as NSError
            if nsError.domain == FirestoreErrorDomain,
               nsError.code == FirestoreErrorCode.permissionDenied.rawValue {
                if let existingSpace = try? await fetchSpace(id: spaceID),
                   existingSpace.memberIDs.contains(userID) {
                    try await refreshSpaces()
                    activeSpace = spaces.first(where: { $0.id == spaceID }) ?? existingSpace
                    return .alreadyMember
                }

                throw Self.makeError("참여할 수 없는 스페이스입니다. 이미 참여 중이거나 권한이 없습니다")
            }

            throw error
        }
    }

    func refreshSpacesIfPossible() async {
        do {
            try await refreshSpaces()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSpaceName(spaceID: String, name: String, requestedBy requesterID: String) async throws {
        try await ensureOwner(spaceID: spaceID, requesterID: requesterID, failureMessage: "방장만 스페이스 이름을 수정할 수 있습니다")

        try await db.collection("spaces").document(spaceID).updateData([
            "name": name
        ])
    }

    func deleteSpace(spaceID: String, requestedBy requesterID: String) async throws {
        try await ensureOwner(spaceID: spaceID, requesterID: requesterID, failureMessage: "방장만 스페이스를 삭제할 수 있습니다")

        let placeSnapshot = try await db.collection("places")
            .whereField("spaceID", isEqualTo: spaceID)
            .getDocuments()

        for placeDocument in placeSnapshot.documents {
            let recordSnapshot = try await db.collection("visitRecords")
                .whereField("spaceID", isEqualTo: spaceID)
                .whereField("placeID", isEqualTo: placeDocument.documentID)
                .getDocuments()

            for recordDocument in recordSnapshot.documents {
                try await recordDocument.reference.delete()
            }

            try await placeDocument.reference.delete()
        }

        let inviteSnapshot = try await db.collection("inviteCodes")
            .whereField("spaceID", isEqualTo: spaceID)
            .getDocuments()

        for inviteDocument in inviteSnapshot.documents {
            try await inviteDocument.reference.delete()
        }

        try await db.collection("spaces").document(spaceID).delete()
        removeLocalSpace(spaceID: spaceID)
        try? await refreshSpaces()
    }

    func removeMember(spaceID: String, userID: String, requestedBy requesterID: String) async throws {
        let createdBy = try await ownerID(for: spaceID)

        guard requesterID == createdBy else {
            throw Self.makeError("방장만 멤버를 제거할 수 있습니다")
        }

        guard userID != createdBy else {
            throw Self.makeError("방장은 제거할 수 없습니다")
        }

        try await db.collection("spaces").document(spaceID).updateData([
            "memberIDs": FieldValue.arrayRemove([userID]),
            "sharedHomeMemberIDs": FieldValue.arrayRemove([userID])
        ])

        if requesterID == userID {
            removeLocalSpace(spaceID: spaceID)
        } else {
            try? await refreshSpaces()
        }
    }

    func leaveSpace(spaceID: String, userID: String) async throws {
        let createdBy = try await ownerID(for: spaceID)

        guard userID != createdBy else {
            throw Self.makeError("방장은 스페이스를 탈퇴할 수 없습니다. 스페이스를 삭제하거나 멤버 관리를 진행해 주세요")
        }

        try await db.collection("spaces").document(spaceID).updateData([
            "memberIDs": FieldValue.arrayRemove([userID]),
            "sharedHomeMemberIDs": FieldValue.arrayRemove([userID])
        ])

        removeLocalSpace(spaceID: spaceID)
        try? await refreshSpaces()
    }

    func setHomeVisibility(spaceID: String, userID: String, isVisible: Bool) async throws {
        try await db.collection("spaces").document(spaceID).updateData([
            "sharedHomeMemberIDs": isVisible ? FieldValue.arrayUnion([userID]) : FieldValue.arrayRemove([userID])
        ])
    }

    func fetchValidInviteCode(for spaceID: String, requestedBy requesterID: String) async throws -> String? {
        try await ensureOwner(spaceID: spaceID, requesterID: requesterID, failureMessage: "방장만 초대 코드를 확인할 수 있습니다")

        let snapshot = try await db.collection("inviteCodes")
            .whereField("spaceID", isEqualTo: spaceID)
            .getDocuments()

        let validDocuments = snapshot.documents.filter { document in
            guard let expiresAt = document.data()["expiresAt"] as? Timestamp else {
                return false
            }
            return expiresAt.dateValue() > Date()
        }

        let sortedDocuments = validDocuments.sorted { lhs, rhs in
            let lhsDate = (lhs.data()["expiresAt"] as? Timestamp)?.dateValue() ?? .distantPast
            let rhsDate = (rhs.data()["expiresAt"] as? Timestamp)?.dateValue() ?? .distantPast
            return lhsDate < rhsDate
        }

        return sortedDocuments.first?.documentID
    }

    private func ensureOwner(spaceID: String, requesterID: String, failureMessage: String) async throws {
        let createdBy = try await ownerID(for: spaceID)
        guard requesterID == createdBy else {
            throw Self.makeError(failureMessage)
        }
    }

    private func ownerID(for spaceID: String) async throws -> String {
        let snapshot = try await db.collection("spaces").document(spaceID).getDocument()
        guard
            snapshot.exists,
            let data = snapshot.data(),
            let createdBy = data["createdBy"] as? String
        else {
            throw Self.makeError("스페이스를 찾을 수 없습니다")
        }

        return createdBy
    }

    private func refreshSpaces() async throws {
        guard let currentUserID else { return }

        let snapshot = try await db.collection("spaces")
            .whereField("memberIDs", arrayContains: currentUserID)
            .getDocuments()

        let refreshedSpaces = snapshot.documents
            .compactMap(makeSpace(from:))
            .sorted { $0.createdAt < $1.createdAt }
        spaces = refreshedSpaces

        if let activeSpace,
           let updatedActiveSpace = refreshedSpaces.first(where: { $0.id == activeSpace.id }) {
            self.activeSpace = updatedActiveSpace
        } else if self.activeSpace == nil || !refreshedSpaces.contains(where: { $0.id == self.activeSpace?.id }) {
            self.activeSpace = refreshedSpaces.first
        }
    }

    private func makeSpace(from document: QueryDocumentSnapshot) -> Space? {
        let data = document.data()

        guard
            let name = data["name"] as? String,
            let memberIDs = data["memberIDs"] as? [String],
            let createdAtTimestamp = data["createdAt"] as? Timestamp,
            let createdBy = data["createdBy"] as? String
        else {
            return nil
        }

        return Space(
            id: document.documentID,
            name: name,
            memberIDs: memberIDs,
            sharedHomeMemberIDs: data["sharedHomeMemberIDs"] as? [String] ?? [],
            createdAt: createdAtTimestamp.dateValue(),
            createdBy: createdBy
        )
    }

    private func fetchSpace(id: String) async throws -> Space? {
        let snapshot = try await db.collection("spaces").document(id).getDocument()
        guard snapshot.exists else {
            return nil
        }

        guard
            let data = snapshot.data(),
            let name = data["name"] as? String,
            let memberIDs = data["memberIDs"] as? [String],
            let createdAtTimestamp = data["createdAt"] as? Timestamp,
            let createdBy = data["createdBy"] as? String
        else {
            return nil
        }

        return Space(
            id: snapshot.documentID,
            name: name,
            memberIDs: memberIDs,
            sharedHomeMemberIDs: data["sharedHomeMemberIDs"] as? [String] ?? [],
            createdAt: createdAtTimestamp.dateValue(),
            createdBy: createdBy
        )
    }

    private func upsertLocalSpace(_ space: Space) {
        if let index = spaces.firstIndex(where: { $0.id == space.id }) {
            spaces[index] = space
        } else {
            spaces.append(space)
            spaces.sort { $0.createdAt < $1.createdAt }
        }
    }

    private func removeLocalSpace(spaceID: String) {
        spaces.removeAll { $0.id == spaceID }
        if activeSpace?.id == spaceID {
            activeSpace = spaces.first
        }
    }

    private static func makeInviteCode(length: Int = 6) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).map { _ in characters.randomElement()! })
    }

    private func makeUniqueInviteCode(maxAttempts: Int = 12) async throws -> String {
        for _ in 0..<maxAttempts {
            let code = Self.makeInviteCode()
            let snapshot = try await db.collection("inviteCodes").document(code).getDocument()
            if !snapshot.exists {
                return code
            }
        }

        throw Self.makeError("초대 코드 생성에 실패했습니다. 다시 시도해 주세요")
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "SpaceService", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
