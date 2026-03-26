import Foundation

struct AppUser: Codable, Identifiable {
    var id: String
    var name: String
    var profileImageURL: String?
    var homeAddress: String?
    var homeLatitude: Double?
    var homeLongitude: Double?
    var createdAt: Date
}
