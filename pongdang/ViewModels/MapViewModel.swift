import SwiftUI
import Combine
import MapKit
import CoreLocation
import FirebaseFirestore

@MainActor
final class MapViewModel: NSObject, ObservableObject {
    struct SearchResult: Identifiable {
        let id = UUID()
        let name: String
        let address: String
        let coordinate: CLLocationCoordinate2D
    }

    @Published var places: [Place] = []
    @Published var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780),
        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
    )
    @Published var userLocation: CLLocationCoordinate2D? = nil
    @Published var isLoading = false

    private struct RepairState {
        static var repairedPlaceIDs: Set<String> = []
        static var repairInFlightPlaceIDs: Set<String> = []
        static var resolvedLocationCache: [String: SearchResult?] = [:]
        static var repairAttemptsThisLaunch = 0
        static let maxRepairAttemptsPerLaunch = 8
    }

    private var listener: ListenerRegistration?
    private let db = Firestore.firestore()
    private let locationManager = CLLocationManager()
    private var shouldCenterOnNextLocationUpdate = false
    private var deferredRepairTask: Task<Void, Never>?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func fetchPlaces(for spaceID: String) {
        listener?.remove()
        listener = db.collection("places")
            .whereField("spaceID", isEqualTo: spaceID)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self, let snapshot else { return }
                Task { @MainActor in
                    let fetchedPlaces = snapshot.documents.compactMap { doc -> Place? in
                        let d = doc.data()
                        guard
                            let name = d["name"] as? String,
                            let address = d["address"] as? String,
                            let lat = d["latitude"] as? Double,
                            let lng = d["longitude"] as? Double,
                            let categoryRaw = d["category"] as? String,
                            let category = PlaceCategory(rawValue: categoryRaw),
                            let addedBy = d["addedBy"] as? String,
                            let addedAtTS = d["addedAt"] as? Timestamp,
                            let isVisited = d["isVisited"] as? Bool
                        else { return nil }
                        return Place(
                            id: doc.documentID,
                            spaceID: spaceID,
                            name: name,
                            address: address,
                            latitude: lat,
                            longitude: lng,
                            category: category,
                            memo: d["memo"] as? String,
                            sourceURL: d["sourceURL"] as? String,
                            addedBy: addedBy,
                            addedAt: addedAtTS.dateValue(),
                            isVisited: isVisited
                        )
                    }
                    self.places = fetchedPlaces
                    self.scheduleCoordinateRepairIfNeeded(for: fetchedPlaces)
                }
            }
    }

    func moveToUserLocation() {
        if let userLocation {
            region = MKCoordinateRegion(
                center: userLocation,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
            return
        }

        shouldCenterOnNextLocationUpdate = true

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        default:
            shouldCenterOnNextLocationUpdate = false
        }
    }

    func applyStartupLocation(_ coordinate: CLLocationCoordinate2D) {
        userLocation = coordinate
        region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    }

    func updateUserLocation(_ coordinate: CLLocationCoordinate2D) {
        userLocation = coordinate
    }

    func reverseGeocode(coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return await MapAddressResolver.reverseGeocode(location)
    }

    /// Finds a shared or stored place's location: the Naver place page first, then
    /// the address, then the name within the address's district. Never returns the
    /// map's default center or a point abroad for a Korean address.
    func resolveSharedLocation(name: String?, address: String?, sourceURL: String? = nil) async -> SearchResult? {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = address?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = [
            trimmedName ?? "",
            trimmedAddress ?? "",
            sourceURL ?? ""
        ].joined(separator: "|").lowercased()

        if let cached = RepairState.resolvedLocationCache[cacheKey] {
            return cached
        }

        if let coordinate = await PlaceCoordinateResolver.naverCoordinate(from: sourceURL) {
            let result = SearchResult(name: trimmedName ?? "장소", address: trimmedAddress ?? "", coordinate: coordinate)
            RepairState.resolvedLocationCache[cacheKey] = result
            return result
        }

        if let trimmedAddress, !trimmedAddress.isEmpty {
            for candidateAddress in addressCandidates(from: trimmedAddress) {
                if let result = await bestAddressMatch(for: candidateAddress, preferredName: trimmedName) {
                    RepairState.resolvedLocationCache[cacheKey] = result
                    return result
                }
            }
        }

        // Name search stays inside Korea and the address's district; a worldwide
        // search used to pin places in Saudi Arabia or the Java Sea.
        if let trimmedName, !trimmedName.isEmpty,
           let coordinate = await PlaceCoordinateResolver.searchByName(trimmedName, address: trimmedAddress ?? "") {
            let result = SearchResult(name: trimmedName, address: trimmedAddress ?? "", coordinate: coordinate)
            RepairState.resolvedLocationCache[cacheKey] = result
            return result
        }

        RepairState.resolvedLocationCache[cacheKey] = nil
        return nil
    }

    func focus(on coordinate: CLLocationCoordinate2D) {
        region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    }

    private func normalizedQuery(for query: String) -> String {
        let lowered = query.lowercased()

        if lowered == "카페" || lowered == "cafe" || lowered == "coffee" || lowered == "커피" {
            return "cafe"
        }

        if lowered == "식당" || lowered == "음식점" || lowered == "맛집" || lowered == "restaurant" {
            return "restaurant"
        }

        return query
    }

    private func pointOfInterestFilter(for query: String) -> MKPointOfInterestFilter? {
        let lowered = query.lowercased()

        if lowered.contains("카페") || lowered.contains("cafe") || lowered.contains("커피") || lowered.contains("coffee") {
            return MKPointOfInterestFilter(including: [.cafe])
        }

        if lowered.contains("식당") || lowered.contains("음식점") || lowered.contains("맛집") || lowered.contains("restaurant") {
            return MKPointOfInterestFilter(including: [.restaurant])
        }

        return nil
    }

    private func rankedResults(_ results: [SearchResult], for query: String, limit: Int) -> [SearchResult] {
        let loweredQuery = query.lowercased()

        return results
            .sorted { lhs, rhs in
                let lhsName = lhs.name.lowercased()
                let rhsName = rhs.name.lowercased()
                let lhsAddress = lhs.address.lowercased()
                let rhsAddress = rhs.address.lowercased()

                let lhsExact = lhsName == loweredQuery ? 0 : 1
                let rhsExact = rhsName == loweredQuery ? 0 : 1
                if lhsExact != rhsExact { return lhsExact < rhsExact }

                let lhsPrefix = lhsName.hasPrefix(loweredQuery) ? 0 : 1
                let rhsPrefix = rhsName.hasPrefix(loweredQuery) ? 0 : 1
                if lhsPrefix != rhsPrefix { return lhsPrefix < rhsPrefix }

                let lhsContains = (lhsName.contains(loweredQuery) || lhsAddress.contains(loweredQuery)) ? 0 : 1
                let rhsContains = (rhsName.contains(loweredQuery) || rhsAddress.contains(loweredQuery)) ? 0 : 1
                if lhsContains != rhsContains { return lhsContains < rhsContains }

                return lhs.name < rhs.name
            }
            .prefix(limit)
            .map { $0 }
    }

    private func firstSearchResult(for query: String, biasToCurrentRegion: Bool = true) async -> SearchResult? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = normalizedQuery(for: query)

        if biasToCurrentRegion {
            request.region = region
            if #available(iOS 18.0, *) {
                request.regionPriority = .required
            }
        }

        if let filter = pointOfInterestFilter(for: query) {
            request.resultTypes = [.pointOfInterest]
            request.pointOfInterestFilter = filter
        } else {
            request.resultTypes = [.pointOfInterest, .address]
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            let mappedResults: [SearchResult] = response.mapItems.compactMap { item -> SearchResult? in
                guard let address = preferredAddress(from: item) else { return nil }
                return SearchResult(
                    name: item.name ?? "장소",
                    address: address,
                    coordinate: MapAddressResolver.coordinate(for: item)
                )
            }

            return rankedResults(mappedResults, for: query, limit: 1).first
        } catch {
            return nil
        }
    }

    private func bestAddressMatch(for address: String, preferredName: String?) async -> SearchResult? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = address
        request.resultTypes = [.address, .pointOfInterest]
        request.region = PlaceCoordinateResolver.koreaRegion
        if #available(iOS 18.0, *) {
            request.regionPriority = .required
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            let mappedResults: [SearchResult] = response.mapItems.compactMap { item -> SearchResult? in
                let coordinate = MapAddressResolver.coordinate(for: item)
                guard let itemAddress = preferredAddress(from: item),
                      !PlaceCoordinateResolver.isSuspicious(coordinate, address: address) else { return nil }
                return SearchResult(
                    name: item.name ?? "장소",
                    address: itemAddress,
                    coordinate: coordinate
                )
            }

            let normalizedAddress = normalizedAddressString(address)
            let normalizedName = preferredName.map(normalizedSearchString)

            let bestMatch = mappedResults
                .sorted { lhs, rhs in
                    let lhsAddress = normalizedAddressString(lhs.address)
                    let rhsAddress = normalizedAddressString(rhs.address)
                    let lhsName = normalizedSearchString(lhs.name)
                    let rhsName = normalizedSearchString(rhs.name)

                    let lhsAddressExact = lhsAddress == normalizedAddress ? 0 : 1
                    let rhsAddressExact = rhsAddress == normalizedAddress ? 0 : 1
                    if lhsAddressExact != rhsAddressExact { return lhsAddressExact < rhsAddressExact }

                    let lhsAddressContains = lhsAddress.contains(normalizedAddress) ? 0 : 1
                    let rhsAddressContains = rhsAddress.contains(normalizedAddress) ? 0 : 1
                    if lhsAddressContains != rhsAddressContains { return lhsAddressContains < rhsAddressContains }

                    if let normalizedName {
                        let lhsNameContains = (lhsName.contains(normalizedName) || lhsAddress.contains(normalizedName)) ? 0 : 1
                        let rhsNameContains = (rhsName.contains(normalizedName) || rhsAddress.contains(normalizedName)) ? 0 : 1
                        if lhsNameContains != rhsNameContains { return lhsNameContains < rhsNameContains }
                    }

                    return lhs.name < rhs.name
                }
                .first

            guard let bestMatch,
                  PlaceCoordinateResolver.isAddressMatch(input: address, candidate: bestMatch.address) else {
                return nil
            }

            return bestMatch
        } catch {
            return nil
        }
    }

    private func normalizedAddressString(_ value: String) -> String {
        PlaceCoordinateResolver.normalizedAddress(value)
    }

    private func normalizedSearchString(_ value: String) -> String {
        value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addressCandidates(from address: String) -> [String] {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let floorStripped = sanitizedAddressForSearch(trimmed)
        let coreRoadAddress = extractedRoadAddress(from: floorStripped)
        var candidates: [String] = []

        if !coreRoadAddress.isEmpty {
            candidates.append(coreRoadAddress)
        }

        if !floorStripped.isEmpty && !candidates.contains(floorStripped) {
            candidates.append(floorStripped)
        }

        if floorStripped != trimmed {
            candidates.append(trimmed)
        }

        let base = candidates.first ?? trimmed
        if base.hasPrefix("서울 ") {
            let dropped = String(base.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !dropped.isEmpty && !candidates.contains(dropped) {
                candidates.append(dropped)
            }
        }

        return candidates
    }

    private func sanitizedAddressForSearch(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*((지하|지상)\s*)?([Bb]\s*)?\d+\s*(층|f|F)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*[Bb]\s*\d+\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+\d+\s*호\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractedRoadAddress(from value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        guard !normalized.isEmpty else { return "" }

        let fullPattern = #"((?:[가-힣]+도|경기|강원|충북|충남|전북|전남|경북|경남|제주)\s+)?((?:[가-힣]+시|서울|부산|대구|인천|광주|대전|울산|세종))\s+([가-힣]+(?:구|군))\s+(?:[가-힣0-9]+(?:동|읍|면|리|가)\s+)?([0-9A-Za-z가-힣]+(?:로|길|대로))\s*(\d+(?:-\d+)?)"#
        if let regex = try? NSRegularExpression(pattern: fullPattern),
           let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           match.numberOfRanges >= 6,
           let cityRange = Range(match.range(at: 2), in: normalized),
           let districtRange = Range(match.range(at: 3), in: normalized),
           let roadRange = Range(match.range(at: 4), in: normalized),
           let numberRange = Range(match.range(at: 5), in: normalized) {
            return [
                String(normalized[cityRange]),
                String(normalized[districtRange]),
                String(normalized[roadRange]),
                String(normalized[numberRange]),
            ].joined(separator: " ")
        }

        let compactPattern = #"((?:[가-힣]+시|서울|부산|대구|인천|광주|대전|울산|세종))\s+([가-힣]+(?:구|군))\s+(?:[가-힣0-9]+(?:동|읍|면|리|가)\s+)?([0-9A-Za-z가-힣]+(?:로|길|대로))\s*(\d+(?:-\d+)?)"#
        if let regex = try? NSRegularExpression(pattern: compactPattern),
           let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           match.numberOfRanges >= 5,
           let cityRange = Range(match.range(at: 1), in: normalized),
           let districtRange = Range(match.range(at: 2), in: normalized),
           let roadRange = Range(match.range(at: 3), in: normalized),
           let numberRange = Range(match.range(at: 4), in: normalized) {
            return [
                String(normalized[cityRange]),
                String(normalized[districtRange]),
                String(normalized[roadRange]),
                String(normalized[numberRange]),
            ].joined(separator: " ")
        }

        return normalized
    }

    private func preferredAddress(from mapItem: MKMapItem?) -> String? {
        MapAddressResolver.address(for: mapItem)
    }


    private func scheduleCoordinateRepairIfNeeded(for places: [Place]) {
        deferredRepairTask?.cancel()

        guard places.contains(where: shouldRepairCoordinates(for:)) else { return }

        deferredRepairTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.repairStoredCoordinatesIfNeeded(for: places)
        }
    }

    private func repairStoredCoordinatesIfNeeded(for places: [Place]) {
        guard RepairState.repairAttemptsThisLaunch < RepairState.maxRepairAttemptsPerLaunch else { return }

        guard let place = places.first(where: { place in
            shouldRepairCoordinates(for: place)
                && !RepairState.repairedPlaceIDs.contains(place.id)
                && !RepairState.repairInFlightPlaceIDs.contains(place.id)
        }) else {
            return
        }

        RepairState.repairInFlightPlaceIDs.insert(place.id)
        RepairState.repairAttemptsThisLaunch += 1

        Task {
            let resolved = await resolveSharedLocation(name: place.name, address: place.address, sourceURL: place.sourceURL)
            await MainActor.run {
                RepairState.repairInFlightPlaceIDs.remove(place.id)
                RepairState.repairedPlaceIDs.insert(place.id)
            }

            guard let resolved,
                  !PlaceCoordinateResolver.isSuspicious(resolved.coordinate, address: place.address) else { return }

            try? await db.collection("places").document(place.id).updateData([
                "latitude": resolved.coordinate.latitude,
                "longitude": resolved.coordinate.longitude
            ])
        }
    }

    /// Only pins that are clearly wrong (the default center, or abroad for a Korean
    /// address) are repaired. Repairing every place that differed from a fresh
    /// search used to move correct pins to wrong results.
    private func shouldRepairCoordinates(for place: Place) -> Bool {
        PlaceCoordinateResolver.isSuspicious(latitude: place.latitude, longitude: place.longitude, address: place.address)
            && !(place.address.isEmpty && (place.sourceURL ?? "").isEmpty)
    }

    deinit {
        listener?.remove()
        deferredRepairTask?.cancel()
    }
}

extension MapViewModel: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if shouldCenterOnNextLocationUpdate {
                manager.requestLocation()
            }
        default:
            shouldCenterOnNextLocationUpdate = false
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        userLocation = coordinate

        if shouldCenterOnNextLocationUpdate {
            shouldCenterOnNextLocationUpdate = false
            region = MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    }
}
