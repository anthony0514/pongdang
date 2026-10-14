import CoreLocation
import Foundation
import HealthKit

/// Reads workouts that have a GPS route from Apple Health.
final class HealthWorkoutImporter {
    struct WorkoutSummary: Identifiable, Hashable {
        let id: String  // HKWorkout UUID
        let activityType: ActivityType
        let startedAt: Date
        let endedAt: Date
        let workout: HKWorkout
    }

    struct ImportedRoute {
        let encodedRoute: String
        let distanceMeters: Double
        let elevationGainMeters: Double?
    }

    private let healthStore = HKHealthStore()

    static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization() async throws {
        try await healthStore.requestAuthorization(
            toShare: [],
            read: [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        )
    }

    /// Recent workouts (newest first) that have a recorded route.
    func recentWorkoutsWithRoutes(days: Int = 90, limit: Int = 100) async throws -> [WorkoutSummary] {
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        let workouts = try await samples(
            of: .workoutType(),
            predicate: HKQuery.predicateForSamples(withStart: startDate, end: nil),
            limit: limit
        ).compactMap { $0 as? HKWorkout }

        var summaries: [WorkoutSummary] = []
        for workout in workouts where try await hasRoute(workout) {
            summaries.append(WorkoutSummary(
                id: workout.uuid.uuidString,
                activityType: Self.activityType(for: workout.workoutActivityType),
                startedAt: workout.startDate,
                endedAt: workout.endDate,
                workout: workout
            ))
        }
        return summaries
    }

    func loadRoute(for workout: HKWorkout) async throws -> ImportedRoute {
        let routes = try await samples(
            of: HKSeriesType.workoutRoute(),
            predicate: HKQuery.predicateForObjects(from: workout),
            limit: HKObjectQueryNoLimit
        ).compactMap { $0 as? HKWorkoutRoute }

        var locations: [CLLocation] = []
        for route in routes {
            locations.append(contentsOf: try await self.locations(in: route))
        }

        // Drop low-accuracy fixes; they show up as spikes on the map.
        let usable = locations
            .filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50 }
            .sorted { $0.timestamp < $1.timestamp }

        guard usable.count >= 2 else {
            throw NSError(domain: "HealthWorkoutImporter", code: 0, userInfo: [NSLocalizedDescriptionKey: "이 운동에는 경로 데이터가 충분하지 않아요."])
        }

        var distance = 0.0
        var elevationGain = 0.0
        for (previous, current) in zip(usable, usable.dropFirst()) {
            distance += current.distance(from: previous)
            let climb = current.altitude - previous.altitude
            if climb > 0 { elevationGain += climb }
        }

        let simplified = RoutePolyline.simplify(usable.map(\.coordinate))
        let metadataGain = (workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?
            .doubleValue(for: .meter())

        return ImportedRoute(
            encodedRoute: RoutePolyline.encode(simplified),
            distanceMeters: distance,
            elevationGainMeters: metadataGain ?? (elevationGain > 0 ? elevationGain : nil)
        )
    }

    private func hasRoute(_ workout: HKWorkout) async throws -> Bool {
        !(try await samples(
            of: HKSeriesType.workoutRoute(),
            predicate: HKQuery.predicateForObjects(from: workout),
            limit: 1
        )).isEmpty
    }

    private func samples(of type: HKSampleType, predicate: NSPredicate?, limit: Int) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            healthStore.execute(query)
        }
    }

    private func locations(in route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { continuation in
            var collected: [CLLocation] = []
            // The handler is called repeatedly with batches until `done` is true.
            let query = HKWorkoutRouteQuery(route: route) { _, batch, done, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                collected.append(contentsOf: batch ?? [])
                if done {
                    continuation.resume(returning: collected)
                }
            }
            healthStore.execute(query)
        }
    }

    private static func activityType(for type: HKWorkoutActivityType) -> ActivityType {
        switch type {
        case .walking: return .walking
        case .hiking: return .hiking
        case .running: return .running
        case .cycling: return .cycling
        default: return .other
        }
    }
}
