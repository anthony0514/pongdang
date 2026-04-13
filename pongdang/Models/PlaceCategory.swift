import Foundation
import SwiftUI

enum PlaceCategory: String, Codable, CaseIterable {
    case restaurant = "음식점"
    case cafe = "카페"
    case bar = "술집"
    case shopping = "쇼핑"
    case nature = "자연"
    case rest = "휴식"
    case activity = "액티비티"
    case leisure = "여가/취미"
    case culture = "문화/예술"
    case other = "기타"

    var displayName: String {
        rawValue.replacingOccurrences(of: "/", with: ", ")
    }
}

extension PlaceCategory {
    var systemImageName: String {
        switch self {
        case .restaurant:
            return "fork.knife"
        case .bar:
            return "wineglass.fill"
        case .cafe:
            return "cup.and.saucer.fill"
        case .nature:
            return "leaf.fill"
        case .culture:
            return "paintpalette.fill"
        case .activity:
            return "figure.run"
        case .leisure:
            return "gamecontroller.fill"
        case .shopping:
            return "bag.fill"
        case .rest:
            return "bed.double.fill"
        case .other:
            return "mappin.and.ellipse"
        }
    }

    var accentColor: Color {
        switch self {
        case .restaurant:
            return Color(hex: "F28C52")
        case .bar:
            return Color(hex: "A8553E")
        case .cafe:
            return Color(hex: "B07A4F")
        case .nature:
            return Color(hex: "58B368")
        case .culture:
            return Color(hex: "8B7CF6")
        case .activity:
            return Color(hex: "2FA7D8")
        case .leisure:
            return Color(hex: "D96C8E")
        case .shopping:
            return Color(hex: "E8885A")
        case .rest:
            return Color(hex: "6CA6A1")
        case .other:
            return Color(hex: "7D8A99")
        }
    }
}
