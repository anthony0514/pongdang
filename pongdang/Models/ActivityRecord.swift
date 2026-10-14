import CoreLocation
import Foundation

/// A workout imported from Apple Health and shared with a space.
struct ActivityRecord: Identifiable, Hashable {
    var id: String  // "{spaceID}_{workoutID}" so a workout is shared to a space only once
    var spaceID: String
    var workoutID: String
    var activityType: ActivityType
    var startedAt: Date
    var endedAt: Date
    var distanceMeters: Double
    var elevationGainMeters: Double?
    var encodedRoute: String  // Google polyline format, simplified
    var createdBy: String
    var createdAt: Date

    var duration: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }

    var routeCoordinates: [CLLocationCoordinate2D] {
        RoutePolyline.decode(encodedRoute)
    }

    static func id(spaceID: String, workoutID: String) -> String {
        "\(spaceID)_\(workoutID)"
    }
}

enum ActivityType: String, CaseIterable {
    case walking
    case hiking
    case running
    case cycling
    case other

    var displayName: String {
        switch self {
        case .walking: return "걷기"
        case .hiking: return "하이킹"
        case .running: return "달리기"
        case .cycling: return "자전거"
        case .other: return "운동"
        }
    }

    var systemImageName: String {
        switch self {
        case .walking: return "figure.walk"
        case .hiking: return "figure.hiking"
        case .running: return "figure.run"
        case .cycling: return "figure.outdoor.cycle"
        case .other: return "figure.mixed.cardio"
        }
    }
}

enum ActivityFormat {
    static func distance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters.rounded()))m"
        }
        return String(format: "%.2fkm", meters / 1000)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)시간 \(minutes)분" : "\(minutes)분"
    }
}
