import Foundation
import Combine
import FirebaseFirestore

@MainActor
final class VisitRecordService: ObservableObject {
    private static let guestUserID = "guest-user"
    private static var migratingSpaceIDs: Set<String> = []

    @Published var isLoading = false
    @Published var errorMessage: String?

    private let db = Firestore.firestore()

    private struct VisitTarget {
        let spaceID: String
        let placeID: String
        let placeName: String
        let visitedAt: Date

        var visitID: String {
            VisitRecord.id(spaceID: spaceID, placeID: placeID, visitedAt: visitedAt)
        }
    }

    // MARK: - Comments

    /// Leaves a rated comment on the place's visit for that day,
    /// creating the visit if nobody has recorded it yet.
    func recordVisit(
        place: Place,
        visitedAt: Date,
        rating: Int,
        body: String,
        photoData: Data? = nil,
        requestedBy requesterID: String
    ) async throws {
        try await perform {
            try self.ensureWritableUser(requesterID)
            try await self.ensureMember(spaceID: place.spaceID, requesterID: requesterID)
            try await self.ensurePlaceMatches(placeID: place.id, spaceID: place.spaceID, placeName: place.name)

            let target = VisitTarget(spaceID: place.spaceID, placeID: place.id, placeName: place.name, visitedAt: visitedAt)
            try await self.writeRatedComment(
                target: target,
                commentID: UUID().uuidString,
                body: body,
                rating: rating,
                userID: requesterID,
                createdAt: Date()
            )
            try await self.updatePlaceVisitedState(placeID: place.id, isVisited: true)

            if let photoData {
                try await self.uploadPhoto(photoData, spaceID: place.spaceID, visitID: target.visitID)
            }
        }
    }

    func addComment(_ body: String, rating: Int, to visit: VisitRecord, requestedBy requesterID: String) async throws {
        try await perform {
            try self.ensureWritableUser(requesterID)
            try await self.ensureMember(spaceID: visit.spaceID, requesterID: requesterID)
            try await self.writeRatedComment(
                target: VisitTarget(spaceID: visit.spaceID, placeID: visit.placeID, placeName: visit.placeName, visitedAt: visit.visitedAt),
                commentID: UUID().uuidString,
                body: body,
                rating: rating,
                userID: requesterID,
                createdAt: Date()
            )
        }
    }

    func updateComment(_ comment: VisitComment, body: String, rating: Int, requestedBy requesterID: String) async throws {
        try await perform {
            try self.ensureWritableUser(requesterID)
            guard comment.createdBy == requesterID, !comment.isLegacy else {
                throw Self.makeError("댓글을 수정할 권한이 없습니다")
            }

            let rating = Self.clampedRating(rating)
            let batch = self.db.batch()
            batch.updateData([
                "body": body,
                "rating": rating,
                "updatedAt": Timestamp(date: Date())
            ], forDocument: self.commentsCollection(visitID: comment.visitID).document(comment.id))
            batch.updateData([
                FieldPath(["ratings", requesterID, comment.id]): rating,
                "updatedAt": Timestamp(date: Date())
            ], forDocument: self.db.collection("visitRecords").document(comment.visitID))
            try await batch.commit()
        }
    }

    /// Deletes a comment and its rating. The visit goes away with its last comment.
    func deleteComment(_ comment: VisitComment, placeID: String, requestedBy requesterID: String) async throws {
        try await perform {
            try self.ensureWritableUser(requesterID)
            guard comment.createdBy == requesterID else {
                throw Self.makeError("댓글을 삭제할 권한이 없습니다")
            }

            if comment.isLegacy {
                try await self.db.collection("visitRecords").document(comment.id).delete()
            } else {
                try await self.deleteRatedComment(comment, userID: requesterID)
            }
            try await self.updatePlaceVisitedState(placeID: placeID, spaceID: comment.spaceID)
        }
    }

    // MARK: - Photo

    /// Uploads a new main photo for the visit, replacing the previous one.
    func setPhoto(_ imageData: Data, for visit: VisitRecord, requestedBy requesterID: String) async throws {
        try await perform {
            try self.ensureWritableUser(requesterID)
            try await self.ensureMember(spaceID: visit.spaceID, requesterID: requesterID)
            try await self.uploadPhoto(imageData, spaceID: visit.spaceID, visitID: visit.id)
        }
    }

    func removePhoto(from visit: VisitRecord, requestedBy requesterID: String) async throws {
        try await perform {
            try self.ensureWritableUser(requesterID)
            try await self.ensureMember(spaceID: visit.spaceID, requesterID: requesterID)

            let visitRef = self.db.collection("visitRecords").document(visit.id)
            let oldPath = try await visitRef.getDocument().data()?["photoPath"] as? String
            try await visitRef.updateData([
                "photoURL": FieldValue.delete(),
                "photoPath": FieldValue.delete(),
                "updatedAt": Timestamp(date: Date())
            ])
            await PhotoStorage.delete(at: oldPath)
        }
    }

    private func uploadPhoto(_ imageData: Data, spaceID: String, visitID: String) async throws {
        let (downloadURL, path) = try await PhotoStorage.upload(imageData, folder: "visitPhotos/\(spaceID)/\(visitID)")

        let visitRef = db.collection("visitRecords").document(visitID)
        let oldPath = try await visitRef.getDocument().data()?["photoPath"] as? String

        do {
            try await visitRef.updateData([
                "photoURL": downloadURL,
                "photoPath": path,
                "updatedAt": Timestamp(date: Date())
            ])
        } catch {
            await PhotoStorage.delete(at: path)
            throw error
        }

        await PhotoStorage.delete(at: oldPath)
    }

    // MARK: - Listeners

    func listenForPlaceRecords(spaceID: String, placeID: String, onChange: @escaping @MainActor ([VisitRecord]) -> Void) -> ListenerRegistration {
        listenForRecords(
            query: db.collection("visitRecords")
                .whereField("spaceID", isEqualTo: spaceID)
                .whereField("placeID", isEqualTo: placeID),
            onChange: onChange
        )
    }

    func listenForSpaceRecords(spaceID: String, onChange: @escaping @MainActor ([VisitRecord]) -> Void) -> ListenerRegistration {
        listenForRecords(
            query: db.collection("visitRecords").whereField("spaceID", isEqualTo: spaceID),
            onChange: onChange
        )
    }

    func listenForComments(of visit: VisitRecord, onChange: @escaping @MainActor ([VisitComment]) -> Void) -> ListenerRegistration {
        commentsCollection(visitID: visit.id)
            .whereField("spaceID", isEqualTo: visit.spaceID)
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    Task { @MainActor in
                        self?.errorMessage = error.localizedDescription
                    }
                    return
                }

                guard let snapshot else { return }
                let comments = snapshot.documents
                    .compactMap { Self.comment(from: $0, visitID: visit.id) }
                    .sorted { $0.createdAt < $1.createdAt }
                Task { @MainActor in
                    onChange(comments)
                }
            }
    }

    private func listenForRecords(query: Query, onChange: @escaping @MainActor ([VisitRecord]) -> Void) -> ListenerRegistration {
        query.addSnapshotListener { [weak self] snapshot, error in
            if let error {
                Task { @MainActor in
                    self?.errorMessage = error.localizedDescription
                }
                return
            }

            guard let snapshot else { return }
            let records = Self.mergedRecords(from: snapshot.documents)
            Task { @MainActor in
                self?.errorMessage = nil
                onChange(records)
            }
        }
    }

    // MARK: - Legacy migration

    /// Converts the requester's old one-per-person records in a space into
    /// rated comments on the shared visit for that day.
    func migrateLegacyRecords(spaceID: String, userID: String) async {
        guard !userID.isEmpty, userID != Self.guestUserID else { return }
        guard !Self.migratingSpaceIDs.contains(spaceID) else { return }
        Self.migratingSpaceIDs.insert(spaceID)
        defer { Self.migratingSpaceIDs.remove(spaceID) }

        guard let snapshot = try? await db.collection("visitRecords")
            .whereField("spaceID", isEqualTo: spaceID)
            .getDocuments() else { return }

        for document in snapshot.documents {
            let data = document.data()
            guard
                Self.isLegacy(data),
                data["createdBy"] as? String == userID,
                let placeID = data["placeID"] as? String,
                let placeName = data["placeName"] as? String,
                let visitedAt = (data["visitedAt"] as? Timestamp)?.dateValue()
            else { continue }

            do {
                // Reusing the old document ID keeps a retried migration idempotent.
                try await writeRatedComment(
                    target: VisitTarget(spaceID: spaceID, placeID: placeID, placeName: placeName, visitedAt: visitedAt),
                    commentID: document.documentID,
                    body: Self.legacyCommentBody(from: data),
                    rating: data["rating"] as? Int ?? 5,
                    userID: userID,
                    createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? visitedAt
                )
                try await document.reference.delete()
            } catch {
                // Leave the old record in place; it still shows up and the next launch retries.
                continue
            }
        }
    }

    // MARK: - Cleanup helpers used by place/space/account deletion

    /// Deletes visit documents together with their comment subcollections.
    static func deleteVisits(_ documents: [QueryDocumentSnapshot], db: Firestore) async throws {
        for document in documents {
            let spaceID = document.data()["spaceID"] as? String ?? ""
            let comments = try await document.reference.collection("comments")
                .whereField("spaceID", isEqualTo: spaceID)
                .getDocuments()
            for comment in comments.documents {
                try await comment.reference.delete()
            }
            try await document.reference.delete()
            await PhotoStorage.delete(at: document.data()["photoPath"] as? String)
        }
    }

    /// Removes one member's comments and ratings from every visit in a space.
    static func removeParticipation(of userID: String, inSpace spaceID: String, db: Firestore) async throws {
        let snapshot = try await db.collection("visitRecords")
            .whereField("spaceID", isEqualTo: spaceID)
            .getDocuments()

        for document in snapshot.documents {
            let data = document.data()
            if isLegacy(data) {
                if data["createdBy"] as? String == userID {
                    try await document.reference.delete()
                }
                continue
            }

            let myComments = try await document.reference.collection("comments")
                .whereField("spaceID", isEqualTo: spaceID)
                .whereField("createdBy", isEqualTo: userID)
                .getDocuments()
            for comment in myComments.documents {
                try await comment.reference.delete()
            }

            let ratings = parseRatings(data["ratings"])
            if ratings.keys.allSatisfy({ $0 == userID }) {
                try await document.reference.delete()
                await PhotoStorage.delete(at: data["photoPath"] as? String)
            } else if ratings[userID] != nil {
                try await document.reference.updateData([
                    FieldPath(["ratings", userID]): FieldValue.delete(),
                    "updatedAt": Timestamp(date: Date())
                ])
            }
        }
    }

    // MARK: - Private

    private func perform(_ operation: () async throws -> Void) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Writes the comment and mirrors its rating onto the visit in one transaction,
    /// creating the visit first if needed so two members recording at once share it.
    private func writeRatedComment(
        target: VisitTarget,
        commentID: String,
        body: String,
        rating: Int,
        userID: String,
        createdAt: Date
    ) async throws {
        let visitID = target.visitID
        let visitRef = db.collection("visitRecords").document(visitID)
        let commentRef = commentsCollection(visitID: visitID).document(commentID)
        let rating = Self.clampedRating(rating)
        let commentData: [String: Any] = [
            "visitID": visitID,
            "spaceID": target.spaceID,
            "placeID": target.placeID,
            "body": body,
            "rating": rating,
            "createdBy": userID,
            "createdAt": Timestamp(date: createdAt)
        ]

        _ = try await db.runTransaction { transaction, errorPointer in
            let snapshot: DocumentSnapshot
            do {
                snapshot = try transaction.getDocument(visitRef)
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }

            if snapshot.exists {
                transaction.updateData([
                    FieldPath(["ratings", userID, commentID]): rating,
                    "updatedAt": Timestamp(date: Date())
                ], forDocument: visitRef)
            } else {
                transaction.setData([
                    "id": visitID,
                    "spaceID": target.spaceID,
                    "placeID": target.placeID,
                    "placeName": target.placeName,
                    "visitedAt": Timestamp(date: VisitRecord.normalizedVisitDate(target.visitedAt)),
                    "ratings": [userID: [commentID: rating]],
                    "createdBy": userID,
                    "createdAt": Timestamp(date: createdAt),
                    "updatedAt": Timestamp(date: Date())
                ], forDocument: visitRef)
            }
            transaction.setData(commentData, forDocument: commentRef)
            return nil
        }
    }

    private func deleteRatedComment(_ comment: VisitComment, userID: String) async throws {
        let visitRef = db.collection("visitRecords").document(comment.visitID)
        let commentRef = commentsCollection(visitID: comment.visitID).document(comment.id)

        // Returns the photo path when the visit itself was deleted.
        let deletedPhotoPath = try await db.runTransaction { transaction, errorPointer -> Any? in
            let snapshot: DocumentSnapshot
            do {
                snapshot = try transaction.getDocument(visitRef)
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }

            transaction.deleteDocument(commentRef)
            guard snapshot.exists else { return nil }

            let ratings = Self.parseRatings(snapshot.data()?["ratings"])
            let myRemaining = (ratings[userID] ?? [:]).filter { $0.key != comment.id }
            let othersRemain = ratings.contains { $0.key != userID }

            if myRemaining.isEmpty && !othersRemain {
                transaction.deleteDocument(visitRef)
                return snapshot.data()?["photoPath"]
            } else if myRemaining.isEmpty {
                transaction.updateData([
                    FieldPath(["ratings", userID]): FieldValue.delete(),
                    "updatedAt": Timestamp(date: Date())
                ], forDocument: visitRef)
            } else {
                transaction.updateData([
                    FieldPath(["ratings", userID, comment.id]): FieldValue.delete(),
                    "updatedAt": Timestamp(date: Date())
                ], forDocument: visitRef)
            }
            return nil
        }

        await PhotoStorage.delete(at: deletedPhotoPath as? String)
    }

    private func updatePlaceVisitedState(placeID: String, spaceID: String) async throws {
        let snapshot = try await db.collection("visitRecords")
            .whereField("spaceID", isEqualTo: spaceID)
            .whereField("placeID", isEqualTo: placeID)
            .limit(to: 1)
            .getDocuments()
        try await updatePlaceVisitedState(placeID: placeID, isVisited: !snapshot.documents.isEmpty)
    }

    private func updatePlaceVisitedState(placeID: String, isVisited: Bool) async throws {
        let placeSnapshot = try await db.collection("places").document(placeID).getDocument()
        guard placeSnapshot.exists else {
            throw Self.makeError("장소를 찾을 수 없습니다")
        }

        try await db.collection("places").document(placeID).updateData([
            "isVisited": isVisited
        ])
    }

    private func commentsCollection(visitID: String) -> CollectionReference {
        db.collection("visitRecords").document(visitID).collection("comments")
    }

    private static func mergedRecords(from documents: [QueryDocumentSnapshot]) -> [VisitRecord] {
        var recordsByID: [String: VisitRecord] = [:]

        for document in documents {
            guard let record = record(from: document) else { continue }

            if var existing = recordsByID[record.id] {
                for (userID, userRatings) in record.ratings {
                    existing.ratings[userID, default: [:]].merge(userRatings) { current, _ in current }
                }
                existing.legacyComments.append(contentsOf: record.legacyComments)
                if record.legacyComments.isEmpty {
                    // Prefer the shared visit document's metadata over a legacy one.
                    existing.createdBy = record.createdBy
                    existing.photoURL = record.photoURL
                    existing.photoPath = record.photoPath
                }
                existing.createdAt = min(existing.createdAt, record.createdAt)
                recordsByID[record.id] = existing
            } else {
                recordsByID[record.id] = record
            }
        }

        return recordsByID.values.sorted { lhs, rhs in
            if lhs.visitedAt == rhs.visitedAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.visitedAt > rhs.visitedAt
        }
    }

    private static func record(from document: QueryDocumentSnapshot) -> VisitRecord? {
        let data = document.data()

        guard
            let placeID = data["placeID"] as? String,
            let spaceID = data["spaceID"] as? String,
            let placeName = data["placeName"] as? String,
            let visitedAt = (data["visitedAt"] as? Timestamp)?.dateValue(),
            let createdBy = data["createdBy"] as? String
        else {
            return nil
        }

        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? visitedAt
        let visitID = VisitRecord.id(spaceID: spaceID, placeID: placeID, visitedAt: visitedAt)

        if isLegacy(data) {
            let rating = data["rating"] as? Int ?? 5
            return VisitRecord(
                id: visitID,
                placeID: placeID,
                spaceID: spaceID,
                placeName: placeName,
                visitedAt: VisitRecord.normalizedVisitDate(visitedAt),
                ratings: [createdBy: [document.documentID: rating]],
                createdBy: createdBy,
                createdAt: createdAt,
                legacyComments: [
                    VisitComment(
                        id: document.documentID,
                        visitID: visitID,
                        spaceID: spaceID,
                        body: legacyCommentBody(from: data),
                        rating: rating,
                        createdBy: createdBy,
                        createdAt: createdAt,
                        isLegacy: true
                    )
                ]
            )
        }

        return VisitRecord(
            id: document.documentID,
            placeID: placeID,
            spaceID: spaceID,
            placeName: placeName,
            visitedAt: visitedAt,
            ratings: parseRatings(data["ratings"]),
            createdBy: createdBy,
            createdAt: createdAt,
            photoURL: data["photoURL"] as? String,
            photoPath: data["photoPath"] as? String
        )
    }

    private static func parseRatings(_ value: Any?) -> [String: [String: Int]] {
        guard let raw = value as? [String: Any] else { return [:] }
        return raw.compactMapValues { userRatings -> [String: Int]? in
            guard let userRatings = userRatings as? [String: Any] else { return nil }
            let parsed = userRatings.compactMapValues { ($0 as? NSNumber)?.intValue }
            return parsed.isEmpty ? nil : parsed
        }
    }

    static func comment(from document: QueryDocumentSnapshot, visitID: String) -> VisitComment? {
        let data = document.data()
        guard
            let spaceID = data["spaceID"] as? String,
            let body = data["body"] as? String,
            let createdBy = data["createdBy"] as? String
        else {
            return nil
        }

        return VisitComment(
            id: document.documentID,
            visitID: visitID,
            spaceID: spaceID,
            body: body,
            rating: (data["rating"] as? NSNumber)?.intValue ?? 0,
            createdBy: createdBy,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
            updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue()
        )
    }

    private static func isLegacy(_ data: [String: Any]) -> Bool {
        data["ratings"] == nil && data["title"] is String
    }

    private static func legacyCommentBody(from data: [String: Any]) -> String {
        let title = (data["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (data["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return [title, body].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func clampedRating(_ rating: Int) -> Int {
        min(max(rating, 1), 5)
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

    private func ensurePlaceMatches(placeID: String, spaceID: String, placeName: String) async throws {
        let snapshot = try await db.collection("places").document(placeID).getDocument()
        guard
            snapshot.exists,
            let data = snapshot.data(),
            let placeSpaceID = data["spaceID"] as? String,
            let name = data["name"] as? String
        else {
            throw Self.makeError("장소를 찾을 수 없습니다")
        }

        guard placeSpaceID == spaceID, name == placeName else {
            throw Self.makeError("방문 기록 대상 장소 정보가 올바르지 않습니다")
        }
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "VisitRecordService", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
