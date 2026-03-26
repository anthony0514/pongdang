import Foundation
import Combine
import FirebaseFirestore

@MainActor
final class SpaceService: ObservableObject {
    @Published var spaces: [Space] = []
    @Published var activeSpace: Space?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private var listener: ListenerRegistration?
    private let db = Firestore.firestore()

    deinit {
        listener?.remove()
    }

    func fetchSpaces(for userID: String) {
        listener?.remove()
        isLoading = true
        errorMessage = nil

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
                } ?? []

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

        return space
    }

    func generateInviteCode(for spaceID: String, createdBy: String) async throws -> String {
        let code = Self.makeInviteCode()
        let createdAt = Date()
        let expiresAt = createdAt.addingTimeInterval(48 * 60 * 60)

        try await db.collection("inviteCodes").document(code).setData([
            "spaceID": spaceID,
            "createdBy": createdBy,
            "createdAt": Timestamp(date: createdAt),
            "expiresAt": Timestamp(date: expiresAt)
        ])

        return code
    }

    func joinSpace(with code: String, userID: String) async throws {
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

        let spaceSnapshot = try await db.collection("spaces").document(spaceID).getDocument()
        guard
            spaceSnapshot.exists,
            let memberIDs = spaceSnapshot.data()?["memberIDs"] as? [String]
        else {
            throw Self.makeError("참여할 스페이스를 찾을 수 없습니다")
        }

        guard !memberIDs.contains(userID) else {
            throw Self.makeError("이미 참여 중인 스페이스입니다")
        }

        try await db.collection("spaces").document(spaceID).updateData([
            "memberIDs": FieldValue.arrayUnion([userID])
        ])
    }

    func updateSpaceName(spaceID: String, name: String) async throws {
        try await db.collection("spaces").document(spaceID).updateData([
            "name": name
        ])
    }

    func deleteSpace(spaceID: String) async throws {
        let placeSnapshot = try await db.collection("places")
            .whereField("spaceID", isEqualTo: spaceID)
            .getDocuments()

        for placeDocument in placeSnapshot.documents {
            let recordSnapshot = try await db.collection("visitRecords")
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
    }

    func removeMember(spaceID: String, userID: String) async throws {
        try await db.collection("spaces").document(spaceID).updateData([
            "memberIDs": FieldValue.arrayRemove([userID]),
            "sharedHomeMemberIDs": FieldValue.arrayRemove([userID])
        ])
    }

    func setHomeVisibility(spaceID: String, userID: String, isVisible: Bool) async throws {
        try await db.collection("spaces").document(spaceID).updateData([
            "sharedHomeMemberIDs": isVisible ? FieldValue.arrayUnion([userID]) : FieldValue.arrayRemove([userID])
        ])
    }

    func fetchValidInviteCode(for spaceID: String) async throws -> String? {
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

    private static func makeInviteCode(length: Int = 6) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).map { _ in characters.randomElement()! })
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "SpaceService", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
