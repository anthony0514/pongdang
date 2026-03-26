import Foundation

enum PlaceCategory: String, Codable, CaseIterable {
    case restaurant = "음식점"
    case cafe = "카페"
    case nature = "자연"
    case culture = "문화/예술"
    case activity = "액티비티"
    case other = "기타"
}
