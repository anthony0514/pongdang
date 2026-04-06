import Foundation
import SwiftUI

enum PlaceCategory: String, Codable, CaseIterable {
    case restaurant = "음식점"
    case cafe = "카페"
    case nature = "자연"
    case culture = "문화/예술"
    case activity = "액티비티"
    case other = "기타"
}

extension PlaceCategory {
    var systemImageName: String {
        switch self {
        case .restaurant:
            return "fork.knife"
        case .cafe:
            return "cup.and.saucer.fill"
        case .nature:
            return "leaf.fill"
        case .culture:
            return "paintpalette.fill"
        case .activity:
            return "figure.run"
        case .other:
            return "mappin.and.ellipse"
        }
    }

    var accentColor: Color {
        switch self {
        case .restaurant:
            return Color(hex: "F28C52")
        case .cafe:
            return Color(hex: "B07A4F")
        case .nature:
            return Color(hex: "58B368")
        case .culture:
            return Color(hex: "8B7CF6")
        case .activity:
            return Color(hex: "2FA7D8")
        case .other:
            return Color(hex: "7D8A99")
        }
    }
}
