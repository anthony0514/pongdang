import Foundation
import Combine
import FirebaseFirestore

@MainActor
final class VisitRecordService: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let db = Firestore.firestore()

    func addVisitRecord(_ record: VisitRecord) async throws {
        isLoading = true
        errorMessage = nil

        do {
            try await db.collection("visitRecords").document(record.id).setData(data(for: record))
            try await updatePlaceVisitedState(placeID: record.placeID, isVisited: true)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            throw error
        }
    }

    func updateVisitRecord(_ record: VisitRecord) async throws {
        isLoading = true
        errorMessage = nil

        do {
            try await db.collection("visitRecords").document(record.id).setData(data(for: record), merge: true)
            try await updatePlaceVisitedState(placeID: record.placeID, isVisited: true)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            throw error
        }
    }

    func deleteVisitRecord(_ record: VisitRecord) async throws {
        isLoading = true
        errorMessage = nil

        do {
            try await db.collection("visitRecords").document(record.id).delete()
            let snapshot = try await db.collection("visitRecords")
                .whereField("placeID", isEqualTo: record.placeID)
                .limit(to: 1)
                .getDocuments()
            try await updatePlaceVisitedState(placeID: record.placeID, isVisited: !snapshot.documents.isEmpty)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            throw error
        }
    }

    func listenForPlaceRecords(placeID: String, onChange: @escaping @MainActor ([VisitRecord]) -> Void) -> ListenerRegistration {
        db.collection("visitRecords")
            .whereField("placeID", isEqualTo: placeID)
            .addSnapshotListener { snapshot, _ in
                let records = snapshot?.documents.compactMap(Self.record(from:)) ?? []
                let sortedRecords = records.sorted { $0.visitedAt > $1.visitedAt }
                Task { @MainActor in
                    onChange(sortedRecords)
                }
            }
    }

    func listenForSpaceRecords(spaceID: String, onChange: @escaping @MainActor ([VisitRecord]) -> Void) -> ListenerRegistration {
        db.collection("visitRecords")
            .whereField("spaceID", isEqualTo: spaceID)
            .addSnapshotListener { snapshot, _ in
                let records = snapshot?.documents.compactMap(Self.record(from:)) ?? []
                let sortedRecords = records.sorted { lhs, rhs in
                    if lhs.visitedAt == rhs.visitedAt {
                        return lhs.createdAt > rhs.createdAt
                    }
                    return lhs.visitedAt > rhs.visitedAt
                }
                Task { @MainActor in
                    onChange(sortedRecords)
                }
            }
    }

    private func updatePlaceVisitedState(placeID: String, isVisited: Bool) async throws {
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
}
