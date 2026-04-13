import Foundation
import Combine
import FirebaseFirestore

@MainActor
final class VisitRecordService: ObservableObject {
    private static let guestUserID = "guest-user"

    @Published var isLoading = false
    @Published var errorMessage: String?

    private let db = Firestore.firestore()

    func addVisitRecord(_ record: VisitRecord, requestedBy requesterID: String) async throws {
        isLoading = true
        errorMessage = nil

        do {
            try ensureWritableUser(requesterID)
            guard requesterID == record.createdBy else {
                throw Self.makeError("방문 기록 작성 요청이 올바르지 않습니다")
            }
            try await ensureMember(spaceID: record.spaceID, requesterID: requesterID)
            try await ensurePlaceMatchesRecord(record)
            try await db.collection("visitRecords").document(record.id).setData(data(for: record))
            try await updatePlaceVisitedState(placeID: record.placeID, isVisited: true, requestedBy: requesterID)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            throw error
        }
    }

    func updateVisitRecord(_ record: VisitRecord, requestedBy requesterID: String) async throws {
        isLoading = true
        errorMessage = nil

        do {
            try ensureWritableUser(requesterID)
            try await ensureMember(spaceID: record.spaceID, requesterID: requesterID)
            let existingRecord = try await fetchRecord(id: record.id)

            guard requesterID == existingRecord.createdBy else {
                throw Self.makeError("방문 기록을 수정할 권한이 없습니다")
            }

            try await db.collection("visitRecords").document(record.id).setData(data(for: record), merge: true)
            try await updatePlaceVisitedState(placeID: record.placeID, isVisited: true, requestedBy: requesterID)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            throw error
        }
    }

    func deleteVisitRecord(_ record: VisitRecord, requestedBy requesterID: String) async throws {
        isLoading = true
        errorMessage = nil

        do {
            try ensureWritableUser(requesterID)
            let existingRecord = try await fetchRecord(id: record.id)
            try await ensureMember(spaceID: existingRecord.spaceID, requesterID: requesterID)

            guard requesterID == existingRecord.createdBy else {
                throw Self.makeError("방문 기록을 삭제할 권한이 없습니다")
            }

            try await db.collection("visitRecords").document(record.id).delete()
            let snapshot = try await db.collection("visitRecords")
                .whereField("spaceID", isEqualTo: record.spaceID)
                .whereField("placeID", isEqualTo: record.placeID)
                .limit(to: 1)
                .getDocuments()
            try await updatePlaceVisitedState(
                placeID: record.placeID,
                isVisited: !snapshot.documents.isEmpty,
                requestedBy: requesterID
            )
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            throw error
        }
    }

    func listenForPlaceRecords(spaceID: String, placeID: String, onChange: @escaping @MainActor ([VisitRecord]) -> Void) -> ListenerRegistration {
        db.collection("visitRecords")
            .whereField("spaceID", isEqualTo: spaceID)
            .whereField("placeID", isEqualTo: placeID)
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    Task { @MainActor in
                        self?.errorMessage = error.localizedDescription
                    }
                    return
                }

                guard let snapshot else { return }
                let records = snapshot.documents.compactMap(Self.record(from:))
                let sortedRecords = records.sorted { $0.visitedAt > $1.visitedAt }
                Task { @MainActor in
                    self?.errorMessage = nil
                    onChange(sortedRecords)
                }
            }
    }

    func listenForSpaceRecords(spaceID: String, onChange: @escaping @MainActor ([VisitRecord]) -> Void) -> ListenerRegistration {
        db.collection("visitRecords")
            .whereField("spaceID", isEqualTo: spaceID)
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    Task { @MainActor in
                        self?.errorMessage = error.localizedDescription
                    }
                    return
                }

                guard let snapshot else { return }
                let records = snapshot.documents.compactMap(Self.record(from:))
                let sortedRecords = records.sorted { lhs, rhs in
                    if lhs.visitedAt == rhs.visitedAt {
                        return lhs.createdAt > rhs.createdAt
                    }
                    return lhs.visitedAt > rhs.visitedAt
                }
                Task { @MainActor in
                    self?.errorMessage = nil
                    onChange(sortedRecords)
                }
            }
    }

    private func updatePlaceVisitedState(placeID: String, isVisited: Bool, requestedBy requesterID: String) async throws {
        let placeSnapshot = try await db.collection("places").document(placeID).getDocument()
        guard
            placeSnapshot.exists,
            let spaceID = placeSnapshot.data()?["spaceID"] as? String
        else {
            throw Self.makeError("장소를 찾을 수 없습니다")
        }

        try await ensureMember(spaceID: spaceID, requesterID: requesterID)
        try await db.collection("places").document(placeID).updateData([
            "isVisited": isVisited
        ])
    }

    private func data(for record: VisitRecord) -> [String: Any] {
        [
            "id": record.id,
            "placeID": record.placeID,
            "spaceID": record.spaceID,
            "placeName": record.placeName,
            "title": record.title,
            "body": record.body as Any,
            "rating": record.rating,
            "photoURLs": record.photoURLs,
            "visitedAt": Timestamp(date: record.visitedAt),
            "createdBy": record.createdBy,
            "createdAt": Timestamp(date: record.createdAt)
        ]
    }

    private static func record(from document: QueryDocumentSnapshot) -> VisitRecord? {
        let data = document.data()

        guard
            let placeID = data["placeID"] as? String,
            let spaceID = data["spaceID"] as? String,
            let placeName = data["placeName"] as? String,
            let title = data["title"] as? String,
            let rating = data["rating"] as? Int,
            let visitedAtTS = data["visitedAt"] as? Timestamp,
            let createdBy = data["createdBy"] as? String
        else {
            return nil
        }

        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? visitedAtTS.dateValue()

        return VisitRecord(
            id: document.documentID,
            placeID: placeID,
            spaceID: spaceID,
            placeName: placeName,
            title: title,
            body: data["body"] as? String,
            rating: rating,
            photoURLs: data["photoURLs"] as? [String] ?? [],
            visitedAt: visitedAtTS.dateValue(),
            createdBy: createdBy,
            createdAt: createdAt
        )
    }

    private func ensureWritableUser(_ requesterID: String) throws {
        guard !requesterID.isEmpty, requesterID != Self.guestUserID else {
            throw Self.makeError("게스트 모드에서는 이 작업을 할 수 없습니다")
        }
    }

    private func ensureMember(spaceID: String, requesterID: String) async throws {
        let snapshot = try await db.collection("spaces").document(spaceID).getDocument()
        guard
            snapshot.exists,
            let memberIDs = snapshot.data()?["memberIDs"] as? [String]
        else {
            throw Self.makeError("스페이스를 찾을 수 없습니다")
        }

        guard memberIDs.contains(requesterID) else {
            throw Self.makeError("이 스페이스에 접근할 권한이 없습니다")
        }
    }

    private func ensurePlaceMatchesRecord(_ record: VisitRecord) async throws {
        let snapshot = try await db.collection("places").document(record.placeID).getDocument()
        guard
            snapshot.exists,
            let data = snapshot.data(),
            let spaceID = data["spaceID"] as? String,
            let placeName = data["name"] as? String
        else {
            throw Self.makeError("장소를 찾을 수 없습니다")
        }

        guard spaceID == record.spaceID, placeName == record.placeName else {
            throw Self.makeError("방문 기록 대상 장소 정보가 올바르지 않습니다")
        }
    }

    private func fetchRecord(id: String) async throws -> VisitRecord {
        let snapshot = try await db.collection("visitRecords").document(id).getDocument()
        guard
            snapshot.exists,
            let data = snapshot.data(),
            let placeID = data["placeID"] as? String,
            let spaceID = data["spaceID"] as? String,
            let placeName = data["placeName"] as? String,
            let title = data["title"] as? String,
            let rating = data["rating"] as? Int,
            let visitedAt = (data["visitedAt"] as? Timestamp)?.dateValue(),
            let createdBy = data["createdBy"] as? String
        else {
            throw Self.makeError("방문 기록을 찾을 수 없습니다")
        }

        return VisitRecord(
            id: snapshot.documentID,
            placeID: placeID,
            spaceID: spaceID,
            placeName: placeName,
            title: title,
            body: data["body"] as? String,
            rating: rating,
            photoURLs: data["photoURLs"] as? [String] ?? [],
            visitedAt: visitedAt,
            createdBy: createdBy,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? visitedAt
        )
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "VisitRecordService", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
