import Foundation

struct Space: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var memberIDs: [String]
    var sharedHomeMemberIDs: [String]
    var createdAt: Date
    var createdBy: String
}
