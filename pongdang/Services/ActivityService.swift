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
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await db.collection("activities").document(activity.id).delete()
        } catch {
            errorMessage = error.localizedDescription
            throw error
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

    static func deleteActivities(spaceID: String, createdBy userID: String? = nil, db: Firestore) async throws {
        var query: Query = db.collection("activities").whereField("spaceID", isEqualTo: spaceID)
        if let userID {
            query = query.whereField("createdBy", isEqualTo: userID)
        }

        for document in try await query.getDocuments().documents {
            try await document.reference.delete()
        }
    }

    private static func activity(from document: QueryDocumentSnapshot) -> ActivityRecord? {
        let data = document.data()
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
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? startedAt
        )
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "ActivityService", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
