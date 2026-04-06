import Foundation

// MARK: - ParsedMapLocation

struct ParsedMapLocation: Codable {
    var name: String?
    var latitude: Double?
    var longitude: Double?
    var address: String?
    var sourceURL: String?

    var hasCoordinates: Bool {
        latitude != nil && longitude != nil
    }
}

// MARK: - MapURLParser

enum MapURLParser {

    // MARK: Public

    /// 공유된 텍스트(URL 포함 가능)에서 지도 위치를 파싱합니다.
    /// 단축 URL(naver.me, goo.gl 등)은 리다이렉트를 따라가므로 async입니다.
    static func parse(from sharedText: String) async -> ParsedMapLocation {
        let urls = extractURLs(from: sharedText)
        var bestResult = ParsedMapLocation()

        // 텍스트에서 장소명 후보 추출
        bestResult.name = extractName(from: sharedText, excluding: urls.map(\.absoluteString))

        for url in urls {
            let resolved = await resolveURL(url)
            var candidate = parseURL(resolved)
            // 장소명이 없으면 위에서 추출한 후보 사용
            if candidate.name == nil {
                candidate.name = bestResult.name
            }
            if candidate.hasCoordinates {
                return candidate
            }
            if bestResult.sourceURL == nil {
                bestResult.sourceURL = resolved.absoluteString
            }
        }

        return bestResult
    }

    // MARK: - URL Parsing

    static func parseURL(_ url: URL) -> ParsedMapLocation {
        guard let host = url.host else {
            return ParsedMapLocation(sourceURL: url.absoluteString)
        }

        if host.contains("map.kakao.com") || host.contains("kakao.com") {
            return parseKakaoMap(url: url)
        } else if host.contains("naver.com") {
            return parseNaverMap(url: url)
        }

        return ParsedMapLocation(sourceURL: url.absoluteString)
    }

    // MARK: - KakaoMap

    // 형식: https://map.kakao.com/link/map/장소명,37.1234,127.5678
    private static func parseKakaoMap(url: URL) -> ParsedMapLocation {
        var result = ParsedMapLocation(sourceURL: url.absoluteString)
        let path = url.path

        if let range = path.range(of: "/link/map/") {
            let payload = String(path[range.upperBound...])
                .removingPercentEncoding ?? ""
            // 마지막 두 콤마 뒤가 lat, lng
            let parts = payload.components(separatedBy: ",")
            if parts.count >= 3,
               let lat = Double(parts[parts.count - 2]),
               let lng = Double(parts[parts.count - 1]) {
                result.latitude = lat
                result.longitude = lng
                result.name = parts.dropLast(2).joined(separator: ",")
            }
        }

        // query param 방식도 시도
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if result.latitude == nil,
           let latStr = components?.queryItems?.first(where: { $0.name == "p" })?.value {
            // p=LAT,LNG
            let parts = latStr.components(separatedBy: ",")
            if parts.count == 2,
               let lat = Double(parts[0]),
               let lng = Double(parts[1]) {
                result.latitude = lat
                result.longitude = lng
            }
        }

        return result
    }

    // MARK: - NaverMap

    // 형식: https://map.naver.com/v5/entry/place/PLACE_ID?c=LNG,LAT,...
    private static func parseNaverMap(url: URL) -> ParsedMapLocation {
        var result = ParsedMapLocation(sourceURL: url.absoluteString)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        // c= 파라미터: LNG,LAT,ZOOM,...
        if let c = components?.queryItems?.first(where: { $0.name == "c" })?.value {
            let parts = c.components(separatedBy: ",")
            if parts.count >= 2,
               let lng = Double(parts[0]),
               let lat = Double(parts[1]) {
                result.latitude = lat
                result.longitude = lng
            }
        }

        // lat/lng 직접 파라미터
        if result.latitude == nil,
           let latStr = components?.queryItems?.first(where: { $0.name == "lat" })?.value,
           let lngStr = components?.queryItems?.first(where: { $0.name == "lng" })?.value,
           let lat = Double(latStr),
           let lng = Double(lngStr) {
            result.latitude = lat
            result.longitude = lng
        }

        // 장소명 파라미터
        if let name = components?.queryItems?.first(where: { $0.name == "name" || $0.name == "title" })?.value {
            result.name = name
        }

        return result
    }

    // MARK: - Helpers

    /// 텍스트에서 URL 배열 추출
    private static func extractURLs(from text: String) -> [URL] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return [] }

        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, range: range)
        return matches.compactMap { match -> URL? in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return URL(string: String(text[matchRange]))
        }
    }

    /// URL 이외의 텍스트에서 장소명 후보 추출
    private static func extractName(from text: String, excluding urls: [String]) -> String? {
        var cleaned = text
        for url in urls {
            cleaned = cleaned.replacingOccurrences(of: url, with: "")
        }
        let name = cleaned
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    /// 단축 URL(naver.me, goo.gl 등)을 최종 URL로 resolve
    private static func resolveURL(_ url: URL) async -> URL {
        let shortHosts = ["naver.me", "kakao.com"]
        let needsResolve = shortHosts.contains(where: { url.host?.contains($0) == true })
        guard needsResolve else { return url }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.httpMethod = "HEAD"

        do {
            // URLSession은 기본적으로 리다이렉트를 따라감
            let (_, response) = try await URLSession.shared.data(for: request)
            return response.url ?? url
        } catch {
            return url
        }
    }
}
