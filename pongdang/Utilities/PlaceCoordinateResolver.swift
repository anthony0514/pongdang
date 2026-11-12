import CoreLocation
import Foundation
import MapKit

/// Turns a place's source link, address or name into coordinates, and spots
/// coordinates that are really a failed lookup (the map's default center or a
/// point abroad for a Korean address).
enum PlaceCoordinateResolver {
    /// The map's initial center (Seoul City Hall). Never trusted as a saved location on its own.
    static let defaultCenter = CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)

    /// Roughly the whole of South Korea, used to keep searches from returning foreign results.
    static let koreaRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 36.0, longitude: 128.0),
        span: MKCoordinateSpan(latitudeDelta: 6.5, longitudeDelta: 7.5)
    )

    private static let metroCities = ["서울", "부산", "대구", "인천", "광주", "대전", "울산", "세종"]

    // MARK: - Sanity checks

    static func isInKorea(_ coordinate: CLLocationCoordinate2D) -> Bool {
        (33.0...38.9).contains(coordinate.latitude) && (124.5...131.95).contains(coordinate.longitude)
    }

    static func isNearDefaultCenter(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let center = CLLocation(latitude: defaultCenter.latitude, longitude: defaultCenter.longitude)
        return location.distance(from: center) < 60
    }

    /// True when the coordinate is almost certainly the result of a failed lookup.
    static func isSuspicious(_ coordinate: CLLocationCoordinate2D, address: String) -> Bool {
        guard CLLocationCoordinate2DIsValid(coordinate),
              !(coordinate.latitude == 0 && coordinate.longitude == 0) else {
            return true
        }
        if looksKorean(address) && !isInKorea(coordinate) { return true }
        if isNearDefaultCenter(coordinate) && !isCityHallAddress(address) { return true }
        return false
    }

    static func isSuspicious(latitude: Double, longitude: Double, address: String) -> Bool {
        isSuspicious(CLLocationCoordinate2D(latitude: latitude, longitude: longitude), address: address)
    }

    private static func looksKorean(_ text: String) -> Bool {
        text.range(of: "[가-힣]", options: .regularExpression) != nil
    }

    private static func isCityHallAddress(_ address: String) -> Bool {
        let normalized = normalizedAddress(address)
        return normalized.contains("세종대로110") || normalized.contains("태평로1가31")
    }

    // MARK: - Naver place links

    /// The numeric place ID in a Naver Map link, such as `map.naver.com/p/entry/place/1234567`.
    static func naverPlaceID(from urlString: String?) -> String? {
        guard let urlString, urlString.contains("naver") else { return nil }
        return firstMatch(
            #"(?:place|restaurant|hairshop|hospital|accommodation|attraction)/(\d{5,})"#,
            in: urlString
        )
    }

    /// Reads the coordinates from the place's mobile page. Returns nil if the page
    /// is gone (closed places) or the result is outside Korea.
    static func naverCoordinate(placeID: String) async -> CLLocationCoordinate2D? {
        guard let url = URL(string: "https://m.place.naver.com/place/\(placeID)/home") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8),
              let x = firstMatch(#""x":"([0-9.]+)""#, in: html).flatMap(Double.init),
              let y = firstMatch(#""y":"([0-9.]+)""#, in: html).flatMap(Double.init) else {
            return nil
        }

        let coordinate = CLLocationCoordinate2D(latitude: y, longitude: x)
        return isInKorea(coordinate) && !isNearDefaultCenter(coordinate) ? coordinate : nil
    }

    static func naverCoordinate(from urlString: String?) async -> CLLocationCoordinate2D? {
        guard let placeID = naverPlaceID(from: urlString) else { return nil }
        return await naverCoordinate(placeID: placeID)
    }

    // MARK: - Name search

    /// Searches Apple Maps for the place name inside Korea. Only accepts a result
    /// whose name matches and, when the address names a district, sits in that district.
    static func searchByName(_ name: String, address: String) async -> CLLocationCoordinate2D? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let district = self.district(in: address)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = [district, trimmedName].compactMap { $0 }.joined(separator: " ")
        request.resultTypes = [.pointOfInterest]
        request.region = koreaRegion
        if #available(iOS 18.0, *) {
            request.regionPriority = .required
        }

        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }

        let wantedName = compact(trimmedName)
        for item in response.mapItems {
            let coordinate = MapAddressResolver.coordinate(for: item)
            guard isInKorea(coordinate), !isNearDefaultCenter(coordinate) else { continue }

            let itemName = compact(item.name ?? "")
            guard !itemName.isEmpty, itemName.contains(wantedName) || wantedName.contains(itemName) else { continue }

            if let district {
                let itemAddress = normalizedAddress(MapAddressResolver.address(for: item) ?? "")
                guard itemAddress.contains(normalizedAddress(district)) else { continue }
            }
            return coordinate
        }
        return nil
    }

    // MARK: - Address matching

    /// Lowercased, without spaces or punctuation, with city and province names
    /// written one way (서울특별시, 서울시 → 서울; 경기도 → 경기).
    static func normalizedAddress(_ value: String) -> String {
        var text = value.lowercased()
        text = text.replacingOccurrences(of: "대한민국", with: "")
        text = text.replacingOccurrences(of: #"^\s*\d{5}\s+"#, with: "", options: .regularExpression)

        let provinces: [(String, String)] = [
            ("경상남도", "경남"), ("경상북도", "경북"), ("전라남도", "전남"), ("전라북도", "전북"),
            ("충청남도", "충남"), ("충청북도", "충북"), ("전북특별자치도", "전북"),
            ("강원특별자치도", "강원"), ("제주특별자치도", "제주"), ("경기도", "경기"), ("강원도", "강원"),
        ]
        for (long, short) in provinces {
            text = text.replacingOccurrences(of: long, with: short)
        }
        text = text.replacingOccurrences(of: #"(특별자치시|특별시|광역시)"#, with: "", options: .regularExpression)
        let metro = metroCities.joined(separator: "|")
        text = text.replacingOccurrences(of: "(\(metro))시(?=\\s|$)", with: "$1", options: .regularExpression)

        return text.replacingOccurrences(of: #"[\s\-\(\)\[\],\.]"#, with: "", options: .regularExpression)
    }

    /// Road name and building number, e.g. "천호대로801" from "서울시 광진구 광장동 천호대로 801".
    static func roadKey(in address: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"([0-9A-Za-z가-힣]+(?:로|길))\s*(\d+(?:-\d+)?)(?![0-9가])"#) else {
            return nil
        }
        let range = NSRange(address.startIndex..., in: address)
        guard let match = regex.firstMatch(in: address, range: range),
              let road = Range(match.range(at: 1), in: address),
              let number = Range(match.range(at: 2), in: address) else {
            return nil
        }
        return String(address[road]) + String(address[number])
    }

    /// The district (구/군), or the city (시) when there is none, e.g. "광진구", "하남시".
    static func district(in address: String) -> String? {
        let tokens = address
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .map(String.init)

        if let gu = tokens.first(where: { ($0.hasSuffix("구") || $0.hasSuffix("군")) && $0.count >= 2 && $0 != "대구" }) {
            return gu
        }
        return tokens.first { token in
            token.hasSuffix("시") && token.count >= 2 && !metroCities.contains(String(token.dropLast()))
        }
    }

    /// Whether a search result's address is specific enough, and close enough to
    /// the typed address, to trust its coordinates.
    static func isAddressMatch(input: String, candidate: String) -> Bool {
        let normalizedInput = normalizedAddress(input)
        let normalizedCandidate = normalizedAddress(candidate)
        guard !normalizedInput.isEmpty, !normalizedCandidate.isEmpty else { return false }

        if normalizedInput == normalizedCandidate || contains(normalizedCandidate, wholeAddress: normalizedInput) {
            return true
        }

        // A shorter result such as a city or district is too coarse to trust,
        // so the result must name the same road and building number.
        guard let inputRoad = roadKey(in: input), let candidateRoad = roadKey(in: candidate) else {
            return false
        }
        guard normalizedAddress(inputRoad) == normalizedAddress(candidateRoad) else { return false }

        if let inputDistrict = district(in: input), let candidateDistrict = district(in: candidate) {
            return inputDistrict == candidateDistrict
        }
        return true
    }

    // MARK: - Helpers

    /// `text` contains `address`, and the match doesn't stop partway through a
    /// building number ("월드컵로12" must not match inside "월드컵로120").
    private static func contains(_ text: String, wholeAddress address: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: address, range: searchStart..<text.endIndex) {
            let endsInsideNumber = address.last?.isNumber == true
                && range.upperBound < text.endIndex
                && text[range.upperBound].isNumber
            if !endsInsideNumber { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    private static func compact(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}
