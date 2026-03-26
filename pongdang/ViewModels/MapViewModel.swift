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
    @Published var sharedHomeUsers: [AppUser] = []
    @Published var searchResults: [SearchResult] = []
    @Published var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780),
        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
    )
    @Published var userLocation: CLLocationCoordinate2D? = nil
    @Published var isLoading = false

    private var listener: ListenerRegistration?
    private let db = Firestore.firestore()
    private let locationManager = CLLocationManager()
    private var hasCenteredOnUserLocation = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
    }

    func fetchPlaces(for spaceID: String) {
        listener?.remove()
        listener = db.collection("places")
            .whereField("spaceID", isEqualTo: spaceID)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self, let snapshot else { return }
                Task { @MainActor in
                    self.places = snapshot.documents.compactMap { doc -> Place? in
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
                }
            }
    }

    func fetchSharedHomeUsers(for space: Space) async {
        guard !space.sharedHomeMemberIDs.isEmpty else {
            sharedHomeUsers = []
            return
        }

        do {
            let snapshot = try await db.collection("users")
                .whereField(FieldPath.documentID(), in: space.sharedHomeMemberIDs)
                .getDocuments()

            sharedHomeUsers = snapshot.documents.compactMap { document in
                let data = document.data()
                guard
                    let name = data["name"] as? String,
                    let createdAtTS = data["createdAt"] as? Timestamp
                else {
                    return nil
                }

                return AppUser(
                    id: document.documentID,
                    name: name,
                    profileImageURL: data["profileImageURL"] as? String,
                    homeAddress: data["homeAddress"] as? String,
                    homeLatitude: data["homeLatitude"] as? Double,
                    homeLongitude: data["homeLongitude"] as? Double,
                    createdAt: createdAtTS.dateValue()
                )
            }
            .filter { $0.homeLatitude != nil && $0.homeLongitude != nil }
        } catch {
            sharedHomeUsers = []
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

        locationManager.requestLocation()
        guard let loc = locationManager.location else { return }
        region = MKCoordinateRegion(
            center: loc.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    }

    func reverseGeocode(coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let request = MKReverseGeocodingRequest(location: location)
        let mapItem = try? await request?.mapItems.first

        if let fullAddress = mapItem?.address?.fullAddress, !fullAddress.isEmpty {
            return fullAddress
        }

        if let shortAddress = mapItem?.address?.shortAddress, !shortAddress.isEmpty {
            return shortAddress
        }

        return mapItem?.name
    }

    func searchPlaces(query: String, region: MKCoordinateRegion?) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = normalizedQuery(for: trimmed)
        request.region = region ?? self.region
        request.regionPriority = .required

        if let filter = pointOfInterestFilter(for: trimmed) {
            request.resultTypes = [.pointOfInterest]
            request.pointOfInterestFilter = filter
        } else {
            request.resultTypes = [.pointOfInterest, .address]
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            let mappedResults = response.mapItems.compactMap { item in
                return SearchResult(
                    name: item.name ?? "장소",
                    address: item.address?.fullAddress ?? item.address?.shortAddress ?? item.name ?? "",
                    coordinate: item.location.coordinate
                )
            }

            searchResults = rankedResults(mappedResults, for: trimmed, limit: 8)
        } catch {
            searchResults = []
        }
    }

    func resolveSharedLocation(name: String?, address: String?) async -> SearchResult? {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = address?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let trimmedAddress, !trimmedAddress.isEmpty,
           let result = await bestAddressMatch(for: trimmedAddress, preferredName: trimmedName) {
            return result
        }

        if let trimmedName, !trimmedName.isEmpty,
           let result = await firstSearchResult(for: trimmedName) {
            return result
        }

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

    private func firstSearchResult(for query: String) async -> SearchResult? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = normalizedQuery(for: query)
        request.region = region
        request.regionPriority = .required

        if let filter = pointOfInterestFilter(for: query) {
            request.resultTypes = [.pointOfInterest]
            request.pointOfInterestFilter = filter
        } else {
            request.resultTypes = [.pointOfInterest, .address]
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            let mappedResults = response.mapItems.compactMap { item in
                SearchResult(
                    name: item.name ?? "장소",
                    address: item.address?.fullAddress ?? item.address?.shortAddress ?? item.name ?? "",
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
        request.region = region
        request.regionPriority = .required
        request.resultTypes = [.address, .pointOfInterest]

        do {
            let response = try await MKLocalSearch(request: request).start()
            let mappedResults = response.mapItems.compactMap { item in
                SearchResult(
                    name: item.name ?? "장소",
                    address: item.address?.fullAddress ?? item.address?.shortAddress ?? item.name ?? "",
                    coordinate: item.location.coordinate
                )
            }

            let loweredAddress = address.lowercased()
            let loweredName = preferredName?.lowercased()

            return mappedResults
                .sorted { lhs, rhs in
                    let lhsAddress = lhs.address.lowercased()
                    let rhsAddress = rhs.address.lowercased()
                    let lhsName = lhs.name.lowercased()
                    let rhsName = rhs.name.lowercased()

                    let lhsAddressExact = lhsAddress == loweredAddress ? 0 : 1
                    let rhsAddressExact = rhsAddress == loweredAddress ? 0 : 1
                    if lhsAddressExact != rhsAddressExact { return lhsAddressExact < rhsAddressExact }

                    let lhsAddressContains = lhsAddress.contains(loweredAddress) ? 0 : 1
                    let rhsAddressContains = rhsAddress.contains(loweredAddress) ? 0 : 1
                    if lhsAddressContains != rhsAddressContains { return lhsAddressContains < rhsAddressContains }

                    if let loweredName {
                        let lhsNameContains = (lhsName.contains(loweredName) || lhsAddress.contains(loweredName)) ? 0 : 1
                        let rhsNameContains = (rhsName.contains(loweredName) || rhsAddress.contains(loweredName)) ? 0 : 1
                        if lhsNameContains != rhsNameContains { return lhsNameContains < rhsNameContains }
                    }

                    return lhs.name < rhs.name
                }
                .first
        } catch {
            return nil
        }
    }

    deinit {
        listener?.remove()
    }
}

extension MapViewModel: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        userLocation = coordinate

        if !hasCenteredOnUserLocation {
            hasCenteredOnUserLocation = true
            region = MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    }
}
