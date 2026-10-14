import Foundation
import Combine
import FirebaseFirestore

@MainActor
final class ActivityService: ObservableObject {
    private static let guestUserID = "guest-user"

    @Published var isLoading = false
    @Published var errorMessage: String?

    private let db = Firestore.firestore()

    func shareWorkout(
        _ summary: HealthWorkoutImporter.WorkoutSummary,
        route: HealthWorkoutImporter.ImportedRoute,
        spaceID: String,
        requestedBy requesterID: String
    ) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard !requesterID.isEmpty, requesterID != Self.guestUserID else {
                throw Self.makeError("게스트 모드에서는 이 작업을 할 수 없습니다")
            }

            let activityID = ActivityRecord.id(spaceID: spaceID, workoutID: summary.id)
            var data: [String: Any] = [
                "id": activityID,
                "spaceID": spaceID,
                "workoutID": summary.id,
                "activityType": summary.activityType.rawValue,
                "startedAt": Timestamp(date: summary.startedAt),
                "endedAt": Timestamp(date: summary.endedAt),
                "distanceMeters": route.distanceMeters,
                "encodedRoute": route.encodedRoute,
                "createdBy": requesterID,
                "createdAt": Timestamp(date: Date())
            ]
            if let elevationGain = route.elevationGainMeters {
                data["elevationGainMeters"] = elevationGain
            }

            try await db.collection("activities").document(activityID).setData(data)
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func deleteActivity(_ activity: ActivityRecord) async throws {
        try await perform {
            let snapshot = try await self.db.collection("activities").document(activity.id).getDocument()
            guard snapshot.exists else { return }
            try await Self.deleteActivityDocument(snapshot, db: self.db)
        }
    }

    // MARK: - Title

    /// Renames the workout. An empty title goes back to the workout type.
    func setTitle(_ title: String, for activity: ActivityRecord, requestedBy requesterID: String) async throws {
        try await perform {
            try self.ensureWritableUser(requesterID)
            try await self.db.collection("activities").document(activity.id).updateData([
                "title": title.isEmpty ? FieldValue.delete() : title
            ])
        }
    }

    // MARK: - Photo

    func setPhoto(_ imageData: Data, for activity: ActivityRecord, requestedBy requesterID: String) async throws {
        try await perform {
            try self.ensureWritableUser(requesterID)

            let activityRef = self.db.collection("activities").document(activity.id)
            let (url, path) = try await PhotoStorage.upload(imageData, folder: "activityPhotos/\(activity.spaceID)/\(activity.id)")
            let oldPath = try await activityRef.getDocument().data()?["photoPath"] as? String

            do {
                try await activityRef.updateData(["photoURL": url, "photoPath": path])
            } catch {
                await PhotoStorage.delete(at: path)
                throw error
            }
            await PhotoStorage.delete(at: oldPath)
        }
    }

    func removePhoto(from activity: ActivityRecord, requestedBy requesterID: String) async throws {
        try await perform {
            try self.ensureWritableUser(requesterID)

            let activityRef = self.db.collection("activities").document(activity.id)
            let oldPath = try await activityRef.getDocument().data()?["photoPath"] as? String
            try await activityRef.updateData([
                "photoURL": FieldValue.delete(),
                "photoPath": FieldValue.delete()
            ])
            await PhotoStorage.delete(at: oldPath)
        }
    }

    // MARK: - Comments

    func addComment(_ body: String, to activity: ActivityRecord, requestedBy requesterID: String) async throws {
        try await perform {
            try self.ensureWritableUser(requesterID)

            try await self.commentsCollection(activityID: activity.id).document(UUID().uuidString).setData([
                "activityID": activity.id,
                "spaceID": activity.spaceID,
                "body": body,
                "createdBy": requesterID,
                "createdAt": Timestamp(date: Date())
            ])
        }
    }

    func updateComment(_ comment: VisitComment, body: String, requestedBy requesterID: String) async throws {
        try await perform {
            guard comment.createdBy == requesterID else {
                throw Self.makeError("댓글을 수정할 권한이 없습니다")
            }

            try await self.commentsCollection(activityID: comment.visitID).document(comment.id).updateData([
                "body": body,
                "updatedAt": Timestamp(date: Date())
            ])
        }
    }

    func deleteComment(_ comment: VisitComment, requestedBy requesterID: String) async throws {
        try await perform {
            guard comment.createdBy == requesterID else {
                throw Self.makeError("댓글을 삭제할 권한이 없습니다")
            }

            try await self.commentsCollection(activityID: comment.visitID).document(comment.id).delete()
        }
    }

    func listenForComments(of activity: ActivityRecord, onChange: @escaping @MainActor ([VisitComment]) -> Void) -> ListenerRegistration {
        commentsCollection(activityID: activity.id)
            .whereField("spaceID", isEqualTo: activity.spaceID)
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    Task { @MainActor in
                        self?.errorMessage = error.localizedDescription
                    }
                    return
                }

                guard let snapshot else { return }
                let comments = snapshot.documents
                    .compactMap { VisitRecordService.comment(from: $0, visitID: activity.id) }
                    .sorted { $0.createdAt < $1.createdAt }
                Task { @MainActor in
                    onChange(comments)
                }
            }
    }

    // MARK: - Listeners

    /// Passes nil once the activity has been deleted.
    func listenForActivity(_ activity: ActivityRecord, onChange: @escaping @MainActor (ActivityRecord?) -> Void) -> ListenerRegistration {
        db.collection("activities").document(activity.id).addSnapshotListener { snapshot, _ in
            guard let snapshot else { return }
            let updated = snapshot.exists ? Self.activity(from: snapshot) : nil
            Task { @MainActor in
                onChange(updated)
            }
        }
    }

    func listenForSpaceActivities(spaceID: String, onChange: @escaping @MainActor ([ActivityRecord]) -> Void) -> ListenerRegistration {
        db.collection("activities")
            .whereField("spaceID", isEqualTo: spaceID)
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    Task { @MainActor in
                        self?.errorMessage = error.localizedDescription
                    }
                    return
                }

                guard let snapshot else { return }
                let activities = snapshot.documents
                    .compactMap(Self.activity(from:))
                    .sorted { $0.startedAt > $1.startedAt }
                Task { @MainActor in
                    onChange(activities)
                }
            }
    }

    /// Workout IDs the user has already shared to this space.
    func sharedWorkoutIDs(spaceID: String, userID: String) async -> Set<String> {
        guard let snapshot = try? await db.collection("activities")
            .whereField("spaceID", isEqualTo: spaceID)
            .whereField("createdBy", isEqualTo: userID)
            .getDocuments() else { return [] }

        return Set(snapshot.documents.compactMap { $0.data()["workoutID"] as? String })
    }

    // MARK: - Cleanup helpers used by space/account deletion

    static func deleteActivities(spaceID: String, db: Firestore) async throws {
        let snapshot = try await db.collection("activities").whereField("spaceID", isEqualTo: spaceID).getDocuments()
        for document in snapshot.documents {
            try await deleteActivityDocument(document, db: db)
        }
    }

    /// Deletes the member's own activities and their comments on others' activities.
    static func removeParticipation(of userID: String, inSpace spaceID: String, db: Firestore) async throws {
        let snapshot = try await db.collection("activities").whereField("spaceID", isEqualTo: spaceID).getDocuments()

        for document in snapshot.documents {
            if document.data()["createdBy"] as? String == userID {
                try await deleteActivityDocument(document, db: db)
                continue
            }

            let myComments = try await document.reference.collection("comments")
                .whereField("spaceID", isEqualTo: spaceID)
                .whereField("createdBy", isEqualTo: userID)
                .getDocuments()
            for comment in myComments.documents {
                try await comment.reference.delete()
            }
        }
    }

    private static func deleteActivityDocument(_ document: DocumentSnapshot, db: Firestore) async throws {
        let data = document.data() ?? [:]
        let comments = try await document.reference.collection("comments")
            .whereField("spaceID", isEqualTo: data["spaceID"] as? String ?? "")
            .getDocuments()
        for comment in comments.documents {
            try await comment.reference.delete()
        }
        try await document.reference.delete()
        await PhotoStorage.delete(at: data["photoPath"] as? String)
    }

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

    private func ensureWritableUser(_ requesterID: String) throws {
        guard !requesterID.isEmpty, requesterID != Self.guestUserID else {
            throw Self.makeError("게스트 모드에서는 이 작업을 할 수 없습니다")
        }
    }

    private func commentsCollection(activityID: String) -> CollectionReference {
        db.collection("activities").document(activityID).collection("comments")
    }

    private static func activity(from document: DocumentSnapshot) -> ActivityRecord? {
        guard let data = document.data() else { return nil }
        guard
            let spaceID = data["spaceID"] as? String,
            let workoutID = data["workoutID"] as? String,
            let startedAt = (data["startedAt"] as? Timestamp)?.dateValue(),
            let endedAt = (data["endedAt"] as? Timestamp)?.dateValue(),
            let distance = (data["distanceMeters"] as? NSNumber)?.doubleValue,
            let encodedRoute = data["encodedRoute"] as? String,
            let createdBy = data["createdBy"] as? String
        else {
            return nil
        }

        return ActivityRecord(
            id: document.documentID,
            spaceID: spaceID,
            workoutID: workoutID,
            activityType: ActivityType(rawValue: data["activityType"] as? String ?? "") ?? .other,
            startedAt: startedAt,
            endedAt: endedAt,
            distanceMeters: distance,
            elevationGainMeters: (data["elevationGainMeters"] as? NSNumber)?.doubleValue,
            encodedRoute: encodedRoute,
            createdBy: createdBy,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? startedAt,
            photoURL: data["photoURL"] as? String,
            photoPath: data["photoPath"] as? String,
            customTitle: (data["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "ActivityService", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
