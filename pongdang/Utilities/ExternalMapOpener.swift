import Foundation

enum ExternalMapOpener {
    static func resolvedURL(for place: Place, preferredApp: PreferredMapApp) -> URL? {
        let query = place.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        switch preferredApp {
        case .kakao:
            return URL(string: "kakaomap://search?q=\(query)&p=\(place.latitude),\(place.longitude)")
        case .naver:
            return URL(string: "nmap://search?query=\(query)&appname=anthony.pongdang")
        }
    }
}

enum PreferredMapApp {
    case kakao
    case naver
}
