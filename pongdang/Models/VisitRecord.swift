import Foundation

struct VisitRecord: Codable, Identifiable, Equatable {
    var id: String
    var placeID: String
    var spaceID: String
    var placeName: String
    var title: String
    var body: String?
    var rating: Int  // 1~5
    var photoURLs: [String]
    var visitedAt: Date
    var createdBy: String
    var createdAt: Date
}
