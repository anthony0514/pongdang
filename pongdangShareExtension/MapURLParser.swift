import Foundation

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

enum MapURLParser {
    static func parse(from sharedText: String) async -> ParsedMapLocation {
        let urls = extractURLs(from: sharedText)
        var bestResult = ParsedMapLocation()
        bestResult.name = extractName(from: sharedText, excluding: urls.map(\.absoluteString))
        bestResult.address = extractAddress(from: sharedText, excluding: urls.map(\.absoluteString))

        for url in urls {
            let resolved = await resolveURL(url)
            var candidate = parseURL(resolved)
            if candidate.name == nil {
                candidate.name = bestResult.name
            }
            if candidate.address == nil {
                candidate.address = bestResult.address
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

    private static func parseKakaoMap(url: URL) -> ParsedMapLocation {
        var result = ParsedMapLocation(sourceURL: url.absoluteString)
        let path = url.path

        if let range = path.range(of: "/link/map/") {
            let payload = String(path[range.upperBound...]).removingPercentEncoding ?? ""
            let parts = payload.components(separatedBy: ",")
            if parts.count >= 3,
               let lat = Double(parts[parts.count - 2]),
               let lng = Double(parts[parts.count - 1]) {
                result.latitude = lat
                result.longitude = lng
                result.name = parts.dropLast(2).joined(separator: ",")
            }
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if result.latitude == nil,
           let latStr = components?.queryItems?.first(where: { $0.name == "p" })?.value {
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

    private static func parseNaverMap(url: URL) -> ParsedMapLocation {
        var result = ParsedMapLocation(sourceURL: url.absoluteString)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        if let c = components?.queryItems?.first(where: { $0.name == "c" })?.value {
            let parts = c.components(separatedBy: ",")
            if parts.count >= 2,
               let lng = Double(parts[0]),
               let lat = Double(parts[1]) {
                result.latitude = lat
                result.longitude = lng
            }
        }

        if result.latitude == nil,
           let latStr = components?.queryItems?.first(where: { $0.name == "lat" })?.value,
           let lngStr = components?.queryItems?.first(where: { $0.name == "lng" })?.value,
           let lat = Double(latStr),
           let lng = Double(lngStr) {
            result.latitude = lat
            result.longitude = lng
        }

        if let name = components?.queryItems?.first(where: { $0.name == "name" || $0.name == "title" })?.value {
            result.name = name
        }

        return result
    }

    private static func extractURLs(from text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return URL(string: String(text[matchRange]))
        }
    }

    private static func extractName(from text: String, excluding urls: [String]) -> String? {
        let lines = cleanedLines(from: text, excluding: urls)
        let name = lines.first ?? ""
        return name.isEmpty ? nil : name
    }

    private static func extractAddress(from text: String, excluding urls: [String]) -> String? {
        let lines = cleanedLines(from: text, excluding: urls)
        guard lines.count >= 2 else { return nil }
        let address = lines[1]
        return address.isEmpty ? nil : address
    }

    private static func cleanedLines(from text: String, excluding urls: [String]) -> [String] {
        var cleaned = text
        for url in urls {
            cleaned = cleaned.replacingOccurrences(of: url, with: "")
        }

        return cleaned
            .components(separatedBy: .newlines)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(
                        of: #"^\[[^\]]+\]\s*"#,
                        with: "",
                        options: .regularExpression
                    )
            }
            .filter { line in
                guard !line.isEmpty else { return false }
                if line.hasPrefix("["), line.hasSuffix("]") {
                    return false
                }
                return true
            }
    }

    private static func resolveURL(_ url: URL) async -> URL {
        let shortHosts = ["naver.me", "kakao.com"]
        let needsResolve = shortHosts.contains(where: { url.host?.contains($0) == true })
        guard needsResolve else { return url }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.httpMethod = "HEAD"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return response.url ?? url
        } catch {
            return url
        }
    }
}
