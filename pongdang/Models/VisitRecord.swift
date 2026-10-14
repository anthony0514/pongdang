import Foundation

// One visit per place per day. Members write rated comments in the
// `comments` subcollection; ratings are mirrored here for list summaries.
struct VisitRecord: Identifiable, Hashable {
    var id: String
    var placeID: String
    var spaceID: String
    var placeName: String
    var visitedAt: Date
    var ratings: [String: [String: Int]]  // userID -> commentID -> 1~5
    var createdBy: String
    var createdAt: Date
    var photoURL: String?
    var photoPath: String?  // Storage path, kept so the file can be deleted
    // Old-format records (one per person) that haven't been migrated yet.
    // Their author's app converts them into comments on next launch.
    var legacyComments: [VisitComment] = []

    var participantIDs: [String] {
        ratings.filter { !$0.value.isEmpty }.keys.sorted()
    }

    var averageRating: Double? {
        let values = ratings.values.flatMap(\.values)
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    static func id(spaceID: String, placeID: String, visitedAt: Date) -> String {
        "\(spaceID)_\(placeID)_\(dayKeyFormatter.string(from: visitedAt))"
    }

    static func normalizedVisitDate(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}

/// A comment on a visit or an activity. Activity comments have no rating (0).
struct VisitComment: Identifiable, Hashable {
    var id: String
    var visitID: String  // parent visit or activity ID
    var spaceID: String
    var body: String
    var rating: Int
    var createdBy: String
    var createdAt: Date
    var updatedAt: Date?
    var isLegacy = false
}
