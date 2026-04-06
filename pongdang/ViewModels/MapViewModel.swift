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
                            tags: d["tags"] as? [String] ?? [],
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
        let request = MKReverseGeocodingRequest(location: location)
        let mapItem = try? await request?.mapItems.first

        return preferredAddress(from: mapItem)
    }

    func resolveSharedLocation(name: String?, address: String?) async -> SearchResult? {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = address?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = [
            trimmedName ?? "",
            trimmedAddress ?? ""
        ].joined(separator: "|").lowercased()

        if let cached = RepairState.resolvedLocationCache[cacheKey] {
            return cached
        }

        if let trimmedAddress, !trimmedAddress.isEmpty {
            for candidateAddress in addressCandidates(from: trimmedAddress) {
                if let result = await bestAddressMatch(for: candidateAddress, preferredName: trimmedName) {
                    RepairState.resolvedLocationCache[cacheKey] = result
                    return result
                }
            }
        }

        if let trimmedName, !trimmedName.isEmpty,
           let result = await firstSearchResult(for: trimmedName, biasToCurrentRegion: false) {
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
            request.regionPriority = .required
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
                    coordinate: item.location.coordinate
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

        do {
            let response = try await MKLocalSearch(request: request).start()
            let mappedResults: [SearchResult] = response.mapItems.compactMap { item -> SearchResult? in
                guard let address = preferredAddress(from: item) else { return nil }
                return SearchResult(
                    name: item.name ?? "장소",
                    address: address,
                    coordinate: item.location.coordinate
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

            guard let bestMatch else { return nil }

            let bestMatchAddress = normalizedAddressString(bestMatch.address)
            guard isAddressMatchAcceptable(input: normalizedAddress, candidate: bestMatchAddress) else {
                return nil
            }

            return bestMatch
        } catch {
            return nil
        }
    }

    private func normalizedAddressString(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[\s\-\(\)\[\],\.]"#, with: "", options: .regularExpression)
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
        var candidates: [String] = []

        if !floorStripped.isEmpty {
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
            .replacingOccurrences(of: #"\s*((지하|지상)\s*)?([Bb]\s*)?\d+\s*(층|f|F)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*[Bb]\s*\d+\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func preferredAddress(from mapItem: MKMapItem?) -> String? {
        guard let address = mapItem?.address else { return nil }

        let fullAddress = address.fullAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullAddress.isEmpty {
            return fullAddress
        }

        if let shortAddress = address.shortAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           !shortAddress.isEmpty {
            return shortAddress
        }

        return nil
    }

    private func isAddressMatchAcceptable(input: String, candidate: String) -> Bool {
        guard !input.isEmpty, !candidate.isEmpty else { return false }
        if input == candidate { return true }
        if candidate.contains(input) || input.contains(candidate) { return true }

        let commonPrefixLength = zip(input, candidate).prefix { $0 == $1 }.count
        let threshold = max(8, Int(Double(input.count) * 0.6))
        return commonPrefixLength >= threshold
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
            let resolved = await resolveSharedLocation(name: place.name, address: place.address)
            await MainActor.run {
                RepairState.repairInFlightPlaceIDs.remove(place.id)
                RepairState.repairedPlaceIDs.insert(place.id)
            }

            guard let resolved else { return }

            let currentLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
            let resolvedLocation = CLLocation(latitude: resolved.coordinate.latitude, longitude: resolved.coordinate.longitude)
            let distance = currentLocation.distance(from: resolvedLocation)

            guard distance >= 300 else { return }

            try? await db.collection("places").document(place.id).updateData([
                "latitude": resolved.coordinate.latitude,
                "longitude": resolved.coordinate.longitude
            ])
        }
    }

    private func shouldRepairCoordinates(for place: Place) -> Bool {
        guard let sourceURL = place.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceURL.isEmpty else {
            return false
        }

        let normalizedAddress = normalizedAddressString(place.address)
        return normalizedAddress.count >= 10
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
