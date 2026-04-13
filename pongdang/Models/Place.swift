import Foundation

struct Place: Codable, Identifiable, Equatable {
    var id: String
    var spaceID: String
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var category: PlaceCategory
    var memo: String?
    var sourceURL: String?
    var addedBy: String
    var addedAt: Date
    var isVisited: Bool
}
