import SwiftUI
import MapKit
import CoreLocation
import FirebaseFirestore

struct MapView: View {
    private enum ExternalMapApp: String {
        case kakao
        case naver

        var title: String {
            switch self {
            case .kakao:
                return "카카오맵"
            case .naver:
                return "네이버지도"
            }
        }
    }

    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appLocationStore: AppLocationStore
    @EnvironmentObject var pendingShareStore: PendingShareStore
    @EnvironmentObject var navigationState: AppNavigationState
    @Environment(\.openURL) private var openURL
    @AppStorage("preferredExternalMapApp") private var preferredExternalMapAppRawValue = ExternalMapApp.kakao.rawValue

    @StateObject private var viewModel = MapViewModel()
    @StateObject private var visitRecordService = VisitRecordService()
    @State private var photoURLByPlaceID: [String: URL] = [:]
    /// Places with a photo, most recently visited first. Earlier ones win when photos overlap.
    @State private var photoPinOrder: [String] = []
    @State private var photoPins = PhotoPinSimulator()
    @State private var mapSize: CGSize = .zero
    @State private var visitRecordListener: ListenerRegistration?
    @State private var selectedPlace: Place? = nil
    /// Places within a few meters of each other (same building), drawn as one pin.
    @State private var placeGroups: [PlaceGroup] = []
    /// The stacked pin the user tapped, shown as a list to pick from.
    @State private var selectedGroup: PlaceGroup? = nil
    /// The place picked from that list; its detail opens once the list closes.
    @State private var placePickedFromGroup: Place? = nil
    @State private var showingPlaceDetail = false
    @State private var showingVisitRecordForm = false
    @State private var showingAddPlace = false
    @State private var longPressCoordinate: CLLocationCoordinate2D? = nil
    @State private var longPressAddress: String? = nil
    @State private var longPressName: String? = nil
    @State private var longPressSourceURL: String? = nil
    @State private var isResolvingAddress = false
    @State private var showingSpaceSheet = false
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
    )

    var body: some View {
        configuredContent
    }

    private var configuredContent: some View {
        lifecycleContent
            .overlay {
                if isResolvingAddress {
                    ZStack {
                        Color.black.opacity(0.12)
                            .ignoresSafeArea()
                        ProgressView("주소 불러오는 중...")
                            .padding(20)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .tint(DesignSystem.Colors.primary)
    }

    private var lifecycleContent: some View {
        lifecycleContentPhaseTwo
            .onChange(of: currentCoordinateKey) { _, _ in
                handleCurrentCoordinateChange(appLocationStore.currentCoordinate)
            }
            .onReceive(viewModel.$region) { region in
                cameraPosition = .region(region)
            }
    }

    private var lifecycleContentPhaseTwo: some View {
        lifecycleContentPhaseOne
            .onChange(of: navigationState.mapFocusRequest) { _, request in
                guard request != nil else { return }
                presentFocusedPlaceIfNeeded(from: viewModel.places)
            }
            .onChange(of: navigationState.selectedTab) { _, selectedTab in
                guard selectedTab == .map else { return }
                presentFocusedPlaceIfNeeded(from: viewModel.places)
            }
    }

    private var lifecycleContentPhaseOne: some View {
        contentWithSheets
            .onAppear(perform: handleOnAppear)
            .onChange(of: pendingShareStore.pendingLocation) { _, location in
                guard location != nil else { return }
                applyPendingShareIfNeeded()
            }
            .onChange(of: spaceService.activeSpace) { _, space in
                handleActiveSpaceChange(space)
            }
            .onChange(of: viewModel.places) { _, places in
                handlePlacesChange(places)
            }
    }

    private var contentWithSheets: some View {
        baseContent
            .sheet(isPresented: $showingPlaceDetail, onDismiss: {
                selectedPlace = nil
            }) {
                placeDetailSheet
            }
            .sheet(isPresented: $showingVisitRecordForm) {
                visitRecordSheet
            }
            .sheet(isPresented: $showingAddPlace) {
                addPlaceSheet
            }
            .sheet(isPresented: $showingSpaceSheet) {
                spaceSheet
            }
            .sheet(item: $selectedGroup, onDismiss: openPlacePickedFromGroup) { group in
                PlaceGroupSheet(group: group) { place in
                    placePickedFromGroup = place
                    selectedGroup = nil
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
            }
    }

    private func openPlacePickedFromGroup() {
        guard let place = placePickedFromGroup else { return }
        placePickedFromGroup = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            selectedPlace = place
            showingPlaceDetail = true
        }
    }

    @ViewBuilder
    private var placeDetailSheet: some View {
        if let selectedPlace {
            PlaceDetailView(place: selectedPlace)
            .environmentObject(spaceService)
            .environmentObject(authService)
            .environmentObject(navigationState)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            // Frosted glass: the map stays faintly visible behind the sheet.
            .presentationBackground(.regularMaterial)
        }
    }

    @ViewBuilder
    private var visitRecordSheet: some View {
        if let selectedPlace {
            VisitRecordFormView(place: selectedPlace)
                .environmentObject(authService)
        }
    }

    private var addPlaceSheet: some View {
        AddPlaceView(
            initialCoordinate: longPressCoordinate,
            initialAddress: longPressAddress,
            initialName: longPressName,
            initialSourceURL: longPressSourceURL
        )
        .environmentObject(spaceService)
        .environmentObject(authService)
    }

    private var spaceSheet: some View {
        NavigationStack {
            SpaceListView()
                .environmentObject(spaceService)
                .environmentObject(authService)
        }
    }

    private var currentCoordinateKey: String {
        guard let coordinate = appLocationStore.currentCoordinate else {
            return "nil"
        }

        return "\(coordinate.latitude),\(coordinate.longitude)"
    }

    private var baseContent: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if geometry.size.width > 0, geometry.size.height > 0 {
                    mapLayer
                } else {
                    Color.clear
                }
                topOverlay
                floatingActionButtons
            }
        }
    }

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                if let userLocation = viewModel.userLocation {
                    Annotation("내 위치", coordinate: userLocation) {
                        UserLocationAnnotationView()
                    }
                }

                ForEach(placeGroups) { group in
                    Annotation(group.title, coordinate: group.coordinate) {
                        PlaceGroupAnnotationView(group: group)
                            .onTapGesture {
                                handleGroupTap(group)
                            }
                    }
                }
            }
            .overlay {
                PhotoPinOverlay(simulator: photoPins)
            }
            .onGeometryChange(for: CGSize.self) { geometry in
                geometry.size
            } action: { size in
                mapSize = size
                updatePhotoPins(using: proxy)
            }
            .onTapGesture { location in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    // Photos are drawn on a layer that ignores touches, so hit-test them here.
                    if let placeID = photoPins.placeID(at: location),
                       let place = viewModel.places.first(where: { $0.id == placeID }) {
                        selectedPlace = place
                        showingPlaceDetail = true
                    } else {
                        selectedPlace = nil
                        showingPlaceDetail = false
                    }
                }
            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            // Every camera frame, so photos follow pins and jostle while zooming.
            .onMapCameraChange(frequency: .continuous) { _ in
                updatePhotoPins(using: proxy)
            }
            .onChange(of: photoPinOrder) { _, _ in
                updatePhotoPins(using: proxy)
            }
            .onChange(of: placeGroups) { _, _ in
                updatePhotoPins(using: proxy)
            }
            .simultaneousGesture(longPressGesture(using: proxy))
        }
    }

    private var topOverlay: some View {
        VStack {
            HStack {
                Spacer()

                Button {
                    showingSpaceSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.3.fill")
                            .font(.caption)

                        Text(spaceService.activeSpace?.name ?? "스페이스 선택")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(glassCapsule)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .zIndex(2)
    }

    private var floatingActionButtons: some View {
        HStack(spacing: 12) {
            Button {
                longPressCoordinate = nil
                longPressAddress = nil
                longPressName = nil
                longPressSourceURL = nil
                showingAddPlace = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.primary)
                    .frame(width: 58, height: 58)
                    .background(glassActionButtonBackground)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("장소 추가")

            Button {
                viewModel.moveToUserLocation()
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.primary)
                    .frame(width: 58, height: 58)
                    .background(glassActionButtonBackground)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("현위치로 이동")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .zIndex(1)
    }

    private func applyPendingShareIfNeeded() {
        guard let pending = pendingShareStore.pendingLocation else { return }
        pendingShareStore.clearPending()

        Task {
            if let lat = pending.latitude, let lng = pending.longitude,
               !PlaceCoordinateResolver.isSuspicious(latitude: lat, longitude: lng, address: pending.address ?? "") {
                let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                await MainActor.run {
                    viewModel.focus(on: coordinate)
                    longPressCoordinate = coordinate
                    longPressAddress = pending.address
                    longPressName = pending.name
                    longPressSourceURL = pending.sourceURL
                    showingAddPlace = true
                }
                return
            }

            let resolved = await viewModel.resolveSharedLocation(
                name: pending.name,
                address: pending.address,
                sourceURL: pending.sourceURL
            )

            await MainActor.run {
                if let resolved {
                    viewModel.focus(on: resolved.coordinate)
                    longPressCoordinate = resolved.coordinate
                    longPressAddress = pending.address ?? resolved.address
                    longPressName = pending.name ?? resolved.name
                    longPressSourceURL = pending.sourceURL
                } else {
                    longPressCoordinate = nil
                    longPressAddress = pending.address
                    longPressName = pending.name
                    longPressSourceURL = pending.sourceURL
                }
                showingAddPlace = true
            }
        }
    }

    private func handleOnAppear() {
        placeGroups = PlaceGroup.make(from: viewModel.places)

        if let startupCoordinate = appLocationStore.currentCoordinate, viewModel.userLocation == nil {
            viewModel.applyStartupLocation(startupCoordinate)
        }

        if let space = spaceService.activeSpace {
            viewModel.fetchPlaces(for: space.id)
            listenForVisitPhotos(spaceID: space.id)
        }
        applyPendingShareIfNeeded()
        presentFocusedPlaceIfNeeded(from: viewModel.places)
    }

    private func handleActiveSpaceChange(_ space: Space?) {
        if let space {
            viewModel.fetchPlaces(for: space.id)
            listenForVisitPhotos(spaceID: space.id)
        } else {
            visitRecordListener?.remove()
            visitRecordListener = nil
            photoURLByPlaceID = [:]
            photoPinOrder = []
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                selectedPlace = nil
            }
        }
    }

    /// Keeps the most recent visit photo for each place, for the zoomed-in photo pins.
    private func listenForVisitPhotos(spaceID: String) {
        visitRecordListener?.remove()
        visitRecordListener = visitRecordService.listenForSpaceRecords(spaceID: spaceID) { records in
            var latest: [String: URL] = [:]
            var order: [String] = []
            // Records arrive newest first, so the first photo seen per place wins.
            for record in records {
                guard latest[record.placeID] == nil, let photo = record.photoURL, let url = URL(string: photo) else { continue }
                latest[record.placeID] = url
                order.append(record.placeID)
            }
            photoURLByPlaceID = latest
            photoPinOrder = order
        }
    }

    /// Feeds current pin screen positions to the photo simulation. Cheap: one projection per place.
    private func updatePhotoPins(using proxy: MapProxy) {
        var pinCenters: [String: CGPoint] = [:]
        // Places in one building share a pin, so their photos float from that pin.
        for group in placeGroups {
            let center = proxy.convert(group.coordinate, to: .local)
            for place in group.places {
                pinCenters[place.id] = center
            }
        }
        let photos = photoPinOrder.compactMap { placeID in
            photoURLByPlaceID[placeID].map { (placeID: placeID, url: $0) }
        }
        photoPins.update(photos: photos, pinCenters: pinCenters, bounds: CGRect(origin: .zero, size: mapSize))
    }

    private func handleGroupTap(_ group: PlaceGroup) {
        if group.places.count == 1, let place = group.places.first {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                selectedPlace = place
                showingPlaceDetail = true
            }
        } else {
            selectedGroup = group
        }
    }

    private func handlePlacesChange(_ places: [Place]) {
        placeGroups = PlaceGroup.make(from: places)

        if let selectedPlace {
            if let updatedPlace = places.first(where: { $0.id == selectedPlace.id }) {
                self.selectedPlace = updatedPlace
            } else {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    self.selectedPlace = nil
                }
                showingPlaceDetail = false
                showingVisitRecordForm = false
            }
        }

        presentFocusedPlaceIfNeeded(from: places)
    }

    private func handleCurrentCoordinateChange(_ coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else { return }

        if viewModel.userLocation == nil {
            viewModel.applyStartupLocation(coordinate)
        } else {
            viewModel.updateUserLocation(coordinate)
        }
    }

    private func presentFocusedPlaceIfNeeded(from places: [Place]) {
        guard let request = navigationState.mapFocusRequest,
              let place = places.first(where: { $0.id == request.placeID }) else { return }

        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            selectedPlace = place
        }
        viewModel.focus(on: place.coordinate)

        if request.shouldPresentPlaceDetail {
            showingPlaceDetail = true
        }

        navigationState.mapFocusRequest = nil
    }

    private func longPressGesture(using proxy: MapProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onEnded { value in
                guard case .second(true, let drag?) = value,
                      let coordinate = proxy.convert(drag.location, from: .local) else {
                    return
                }

                Task {
                    selectedPlace = nil
                    longPressCoordinate = coordinate
                    longPressName = nil
                    isResolvingAddress = true
                    longPressAddress = await viewModel.reverseGeocode(coordinate: coordinate)
                    isResolvingAddress = false
                    showingAddPlace = true
                }
            }
    }

    private var preferredExternalMapApp: ExternalMapApp {
        ExternalMapApp(rawValue: preferredExternalMapAppRawValue) ?? .kakao
    }

    private func openInPreferredMapApp(for place: Place) {
        let preferredApp: PreferredMapApp = preferredExternalMapApp == .kakao ? .kakao : .naver
        if let url = ExternalMapOpener.resolvedURL(for: place, preferredApp: preferredApp) {
            openURL(url)
        }
    }

    private var glassCircle: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.cardHighlight,
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: DesignSystem.Colors.cardShadow, radius: 14, y: 8)
    }

    private var glassCapsule: some View {
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.cardHighlight,
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Capsule()
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: DesignSystem.Colors.cardShadow, radius: 16, y: 9)
    }

    private var glassRoundedRect: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.cardHighlight,
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: DesignSystem.Colors.cardShadow, radius: 16, y: 9)
    }

    private var glassActionButtonBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.cardHighlight.opacity(1.15),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.24),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                )

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: DesignSystem.Colors.cardShadow.opacity(0.9), radius: 14, y: 7)
    }

}

private struct PlaceAnnotationView: View {
    let place: Place

    var body: some View {
        pin
    }

    private var pin: some View {
        ZStack {
            Circle()
                .fill(place.category.accentColor)
                .frame(width: PhotoPinSimulator.pinSize, height: PhotoPinSimulator.pinSize)

            Image(systemName: place.category.systemImageName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)

            if place.isVisited {
                Circle()
                    .fill(Color.green)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 5, weight: .black))
                            .foregroundStyle(.white)
                    )
                    .offset(x: 9, y: -9)
            }
        }
        .overlay(
            Circle()
                .stroke(Color.white.opacity(0.45), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
    }
}

/// Places close enough to share one pin, typically shops in the same building.
private struct PlaceGroup: Identifiable, Equatable {
    /// Places this close (in meters) are drawn as one stacked pin.
    static let mergeDistance: CLLocationDistance = 20

    let places: [Place]

    var id: String { places.map(\.id).joined(separator: "|") }

    var coordinate: CLLocationCoordinate2D {
        let count = Double(places.count)
        return CLLocationCoordinate2D(
            latitude: places.map(\.latitude).reduce(0, +) / count,
            longitude: places.map(\.longitude).reduce(0, +) / count
        )
    }

    var title: String {
        guard let first = places.first else { return "" }
        return places.count == 1 ? first.name : "\(first.name) 외 \(places.count - 1)곳"
    }

    /// Groups places within `mergeDistance` of a group's first place. Order inside
    /// a group is stable: most recently added first.
    static func make(from places: [Place]) -> [PlaceGroup] {
        var buckets: [(anchor: CLLocation, places: [Place])] = []

        for place in places.sorted(by: { $0.addedAt > $1.addedAt }) {
            let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
            if let index = buckets.firstIndex(where: { $0.anchor.distance(from: location) <= mergeDistance }) {
                buckets[index].places.append(place)
            } else {
                buckets.append((location, [place]))
            }
        }

        return buckets.map { PlaceGroup(places: $0.places) }
    }
}

/// A single pin, or a stacked pin with a count when several places share a spot.
private struct PlaceGroupAnnotationView: View {
    let group: PlaceGroup

    var body: some View {
        if group.places.count == 1, let place = group.places.first {
            PlaceAnnotationView(place: place)
        } else if let front = group.places.first {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    // A second disc peeking out behind reads as "more than one".
                    Circle()
                        .fill(group.places[1].category.accentColor.opacity(0.85))
                        .frame(width: PhotoPinSimulator.pinSize, height: PhotoPinSimulator.pinSize)
                        .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 0.8))
                        .offset(x: 4, y: -3)

                    PlaceAnnotationView(place: front)
                }

                Text("\(group.places.count)")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .overlay(Capsule().stroke(Color.white, lineWidth: 1))
                    .offset(x: 12, y: -11)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(group.title)
        }
    }
}

/// The places behind a stacked pin, to pick one.
private struct PlaceGroupSheet: View {
    let group: PlaceGroup
    let onSelect: (Place) -> Void

    var body: some View {
        NavigationStack {
            List(group.places) { place in
                Button {
                    onSelect(place)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(place.category.accentColor)
                                .frame(width: 32, height: 32)
                            Image(systemName: place.category.systemImageName)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(place.category.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if place.isVisited {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("이 건물의 장소 \(group.places.count)곳")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct UserLocationAnnotationView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(0.25))
                .frame(width: 24, height: 24)

            Circle()
                .fill(Color.blue)
                .frame(width: 12, height: 12)
        }
    }
}

private extension Place {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
