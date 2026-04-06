import SwiftUI
import MapKit
import CoreLocation

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
    @State private var selectedPlace: Place? = nil
    @State private var showingPlaceDetail = false
    @State private var showingVisitRecordForm = false
    @State private var showingAddPlace = false
    @State private var longPressCoordinate: CLLocationCoordinate2D? = nil
    @State private var longPressAddress: String? = nil
    @State private var longPressName: String? = nil
    @State private var longPressSourceURL: String? = nil
    @State private var isResolvingAddress = false
    @State private var showingSpaceSheet = false
    @State private var selectedPlaceDetailDetent: PresentationDetent = .fraction(0.34)
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
        let contentWithSheets = AnyView(
            baseContent
                .sheet(isPresented: $showingPlaceDetail, onDismiss: {
                    selectedPlace = nil
                }) {
                    if let selectedPlace {
                        PlaceDetailView(
                            place: selectedPlace,
                            showsFloatingWriteButton: selectedPlaceDetailDetent == .large
                        )
                            .environmentObject(spaceService)
                            .environmentObject(authService)
                            .environmentObject(navigationState)
                            .presentationDetents([.fraction(0.34), .large], selection: $selectedPlaceDetailDetent)
                            .presentationDragIndicator(.visible)
                    }
                }
                .sheet(isPresented: $showingVisitRecordForm) {
                    if let selectedPlace {
                        VisitRecordFormView(place: selectedPlace, existingRecord: nil)
                            .environmentObject(authService)
                    }
                }
                .sheet(isPresented: $showingAddPlace) {
                    AddPlaceView(
                        initialCoordinate: longPressCoordinate,
                        initialAddress: longPressAddress,
                        initialName: longPressName,
                        initialSourceURL: longPressSourceURL
                    )
                    .environmentObject(spaceService)
                    .environmentObject(authService)
                }
                .sheet(isPresented: $showingSpaceSheet) {
                    NavigationStack {
                        SpaceListView()
                            .environmentObject(spaceService)
                            .environmentObject(authService)
                    }
                }
        )

        let contentWithLifecycle = AnyView(
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
                .onChange(of: navigationState.mapFocusRequest) { _, request in
                    guard request != nil else { return }
                    presentFocusedPlaceIfNeeded(from: viewModel.places)
                }
                .onChange(of: navigationState.selectedTab) { _, selectedTab in
                    guard selectedTab == .map else { return }
                    presentFocusedPlaceIfNeeded(from: viewModel.places)
                }
                .onChange(of: appLocationStore.currentCoordinate) { _, coordinate in
                    handleCurrentCoordinateChange(coordinate)
                }
                .onReceive(viewModel.$region) { region in
                    cameraPosition = .region(region)
                }
        )

        return contentWithLifecycle
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

                ForEach(viewModel.places) { place in
                    Annotation(place.name, coordinate: place.coordinate) {
                        PlaceAnnotationView(place: place)
                            .onTapGesture {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                    selectedPlace = place
                                    selectedPlaceDetailDetent = .fraction(0.34)
                                    showingPlaceDetail = true
                                }
                            }
                    }
                }
            }
            .onTapGesture {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    selectedPlace = nil
                    showingPlaceDetail = false
                }
            }
            .mapControls {
                MapCompass()
                MapScaleView()
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
            if let lat = pending.latitude, let lng = pending.longitude {
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
                address: pending.address
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
        if let startupCoordinate = appLocationStore.currentCoordinate, viewModel.userLocation == nil {
            viewModel.applyStartupLocation(startupCoordinate)
        }

        if let space = spaceService.activeSpace {
            viewModel.fetchPlaces(for: space.id)
        }
        applyPendingShareIfNeeded()
        presentFocusedPlaceIfNeeded(from: viewModel.places)
    }

    private func handleActiveSpaceChange(_ space: Space?) {
        if let space {
            viewModel.fetchPlaces(for: space.id)
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                selectedPlace = nil
            }
        }
    }

    private func handlePlacesChange(_ places: [Place]) {
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
            selectedPlaceDetailDetent = request.prefersCompactPlaceDetailSheet ? .fraction(0.34) : .large
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
        ZStack {
            Circle()
                .fill(place.category.accentColor)
                .frame(width: 24, height: 24)

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
