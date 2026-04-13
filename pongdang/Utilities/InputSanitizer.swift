import Foundation

enum InputSanitizer {
    enum Rule {
        case displayName
        case spaceName
        case placeName
        case address
        case tag
        case title
        case body
        case search
        case inviteCode

        var maxLength: Int {
            switch self {
            case .displayName: return 20
            case .spaceName: return 24
            case .placeName: return 40
            case .address: return 120
            case .tag: return 16
            case .title: return 40
            case .body: return 500
            case .search: return 30
            case .inviteCode: return 6
            }
        }

        var allowsNewlines: Bool {
            self == .body
        }

        var allowsAllVisibleSymbols: Bool {
            self != .inviteCode
        }
    }

    static func sanitize(_ text: String, as rule: Rule) -> String {
        let filteredScalars = text.unicodeScalars.filter { scalar in
            isAllowed(scalar, for: rule)
        }

        let normalized = String(String.UnicodeScalarView(filteredScalars))
        return truncate(normalized, as: rule)
    }

    static func truncate(_ text: String, as rule: Rule) -> String {
        guard text.count > rule.maxLength else { return text }
        return String(text.prefix(rule.maxLength))
    }

    private static func isAllowed(_ scalar: UnicodeScalar, for rule: Rule) -> Bool {
        if scalar == "\n" {
            return rule.allowsNewlines
        }

        if CharacterSet.whitespaces.contains(scalar) {
            return true
        }

        if rule == .inviteCode {
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
                return true
            default:
                return false
            }
        }

        if rule.allowsAllVisibleSymbols {
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.illegalCharacters.contains(scalar) {
                return false
            }
            return true
        }

        return false
    }
}
