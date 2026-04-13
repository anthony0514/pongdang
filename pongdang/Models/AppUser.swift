import Foundation

struct AppUser: Codable, Identifiable {
    var id: String
    var name: String
    var profileImageURL: String?
    var homeAddress: String?
    var homeLatitude: Double?
    var homeLongitude: Double?
    var receivesNewMemberNotifications: Bool
    var receivesNewPlaceNotifications: Bool
    var receivesNewMemoNotifications: Bool
    var fcmTokens: [String]
    var createdAt: Date

    init(
        id: String,
        name: String,
        profileImageURL: String?,
        homeAddress: String?,
        homeLatitude: Double?,
        homeLongitude: Double?,
        receivesNewMemberNotifications: Bool = true,
        receivesNewPlaceNotifications: Bool = true,
        receivesNewMemoNotifications: Bool = true,
        fcmTokens: [String] = [],
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.profileImageURL = profileImageURL
        self.homeAddress = homeAddress
        self.homeLatitude = homeLatitude
        self.homeLongitude = homeLongitude
        self.receivesNewMemberNotifications = receivesNewMemberNotifications
        self.receivesNewPlaceNotifications = receivesNewPlaceNotifications
        self.receivesNewMemoNotifications = receivesNewMemoNotifications
        self.fcmTokens = fcmTokens
        self.createdAt = createdAt
    }
}

extension AppUser {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case profileImageURL
        case homeAddress
        case homeLatitude
        case homeLongitude
        case receivesNewMemberNotifications
        case receivesNewPlaceNotifications
        case receivesNewMemoNotifications
        case fcmTokens
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        profileImageURL = try container.decodeIfPresent(String.self, forKey: .profileImageURL)
        homeAddress = try container.decodeIfPresent(String.self, forKey: .homeAddress)
        homeLatitude = try container.decodeIfPresent(Double.self, forKey: .homeLatitude)
        homeLongitude = try container.decodeIfPresent(Double.self, forKey: .homeLongitude)
        receivesNewMemberNotifications = try container.decodeIfPresent(Bool.self, forKey: .receivesNewMemberNotifications) ?? true
        receivesNewPlaceNotifications = try container.decodeIfPresent(Bool.self, forKey: .receivesNewPlaceNotifications) ?? true
        receivesNewMemoNotifications = try container.decodeIfPresent(Bool.self, forKey: .receivesNewMemoNotifications) ?? true
        fcmTokens = try container.decodeIfPresent([String].self, forKey: .fcmTokens) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}
