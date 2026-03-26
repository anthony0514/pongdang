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
    @State private var showingSettings = false
    @State private var searchText = ""
    @State private var isSearching = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
    )

    var body: some View {
        ZStack(alignment: .bottom) {
            MapReader { proxy in
                Map(position: $cameraPosition) {
                    if let userLocation = viewModel.userLocation {
                        Annotation("내 위치", coordinate: userLocation) {
                            UserLocationAnnotationView()
                        }
                    }

                    ForEach(viewModel.sharedHomeUsers, id: \.id) { user in
                        if let coordinate = user.homeCoordinate {
                            Annotation("\(user.name)의 집", coordinate: coordinate) {
                                HomeAnnotationView(userName: user.name)
                            }
                        }
                    }

                    ForEach(viewModel.places) { place in
                        Annotation(place.name, coordinate: place.coordinate) {
                            PlaceAnnotationView(place: place)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                        selectedPlace = place
                                    }
                                }
                        }
                    }
                }
                .onTapGesture {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        selectedPlace = nil
                    }
                    isSearchFieldFocused = false
                }
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }
                .simultaneousGesture(longPressGesture(using: proxy))
            }

            VStack {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
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

                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 44, height: 44)
                                .background(glassCircle)
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField("장소 검색", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($isSearchFieldFocused)
                            .onSubmit {
                                performSearch()
                            }

                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                                viewModel.searchResults = []
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(glassRoundedRect)

                    if !viewModel.searchResults.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(viewModel.searchResults) { result in
                                Button {
                                    applySearchResult(result)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        Text(result.address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                }
                                .buttonStyle(.plain)

                                if result.id != viewModel.searchResults.last?.id {
                                    Divider()
                                        .overlay(Color.white.opacity(0.16))
                                }
                            }
                        }
                        .background(glassRoundedRect)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .zIndex(2)

            if let selectedPlace {
                PlacePreviewCard(
                    place: selectedPlace,
                    onWriteVisitRecord: {
                        showingVisitRecordForm = true
                    },
                    onOpenMapApp: {
                        openInPreferredMapApp(for: selectedPlace)
                    }
                )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture {
                        showingPlaceDetail = true
                    }
            }

            VStack(spacing: 12) {
                Button {
                    longPressCoordinate = nil
                    longPressAddress = nil
                    longPressName = nil
                    longPressSourceURL = nil
                    showingAddPlace = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .background(glassCircle)
                }

                Button {
                    viewModel.moveToUserLocation()
                } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(glassCircle)
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 20)
            .offset(y: selectedPlace == nil ? 0 : -96)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: selectedPlace != nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .zIndex(1)
        }
        .sheet(isPresented: $showingPlaceDetail) {
            if let selectedPlace {
                PlaceDetailView(place: selectedPlace)
                    .environmentObject(spaceService)
                    .environmentObject(authService)
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
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
                    .environmentObject(spaceService)
                    .environmentObject(authService)
            }
        }
        .onAppear {
            if let space = spaceService.activeSpace {
                viewModel.fetchPlaces(for: space.id)
                Task {
                    await viewModel.fetchSharedHomeUsers(for: space)
                }
            }
            // Share Extension에서 앱을 열었을 때 pending 데이터 처리
            applyPendingShareIfNeeded()
        }
        .onChange(of: pendingShareStore.pendingLocation) { _, location in
            guard location != nil else { return }
            applyPendingShareIfNeeded()
        }
        .onChange(of: spaceService.activeSpace) { _, space in
            if let space {
                viewModel.fetchPlaces(for: space.id)
                Task {
                    await viewModel.fetchSharedHomeUsers(for: space)
                }
            } else {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    selectedPlace = nil
                }
                viewModel.sharedHomeUsers = []
            }
        }
        .onChange(of: viewModel.places) { _, places in
            guard let selectedPlace else { return }

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
        .onChange(of: navigationState.focusedPlaceID) { _, placeID in
            guard let placeID,
                  let place = viewModel.places.first(where: { $0.id == placeID }) else { return }

            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                selectedPlace = place
            }
            viewModel.focus(on: place.coordinate)
            navigationState.focusedPlaceID = nil
        }
        .onReceive(viewModel.$region) { region in
            cameraPosition = .region(region)
        }
        .onChange(of: searchText) { _, newValue in
            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                viewModel.searchResults = []
                return
            }

            guard !isSearching else { return }
            performSearch()
        }
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

    private func performSearch() {
        Task {
            isSearching = true
            await viewModel.searchPlaces(
                query: searchText,
                region: cameraRegion
            )
            isSearching = false
        }
    }

    private func applySearchResult(_ result: MapViewModel.SearchResult) {
        searchText = result.name
        viewModel.searchResults = []
        selectedPlace = nil
        isSearchFieldFocused = false
        longPressCoordinate = result.coordinate
        longPressAddress = result.address
        longPressName = result.name
        viewModel.focus(on: result.coordinate)
        showingAddPlace = true
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
                    isSearchFieldFocused = false
                    longPressCoordinate = coordinate
                    longPressName = nil
                    isResolvingAddress = true
                    longPressAddress = await viewModel.reverseGeocode(coordinate: coordinate)
                    isResolvingAddress = false
                    showingAddPlace = true
                }
            }
    }

    private var cameraRegion: MKCoordinateRegion? {
        viewModel.region
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
}

private struct PlaceAnnotationView: View {
    let place: Place

    var body: some View {
        ZStack {
            Circle()
                .fill(place.isVisited ? Color.green : Color.pink)
                .frame(width: 22, height: 22)

            Image(systemName: place.isVisited ? "checkmark" : "mappin")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
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

private struct HomeAnnotationView: View {
    let userName: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "house.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.orange))

            Text(userName)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.24), lineWidth: 0.8)
                        )
                )
        }
    }
}

struct PlacePreviewCard: View {
    let place: Place
    let onWriteVisitRecord: () -> Void
    let onOpenMapApp: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text(place.name)
                    .font(.headline)
                    .fontWeight(.bold)

                HStack(spacing: 8) {
                    Text(place.category.rawValue)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Capsule())

                    Text(place.isVisited ? "방문 완료" : "미방문")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(visitStatusColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(visitStatusBackground)
                        .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if place.isVisited {
                Button(action: onOpenMapApp) {
                    Image(systemName: "link")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 56, height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("외부 지도 앱에서 열기")
            } else {
                HStack(alignment: .center, spacing: 8) {
                    Button(action: onOpenMapApp) {
                        Image(systemName: "link")
                        .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 42, height: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("외부 지도 앱에서 열기")

                    Button(action: onWriteVisitRecord) {
                        Image(systemName: "pencil")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.accentColor)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("방문 기록 작성")
                }
            }
        }
        .padding(16)
        .pondangGlassCard(cornerRadius: 22)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                .blur(radius: 0.4)
        )
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var visitStatusColor: Color {
        place.isVisited ? .green : .gray
    }

    private var visitStatusBackground: Color {
        (place.isVisited ? Color.green : Color.gray).opacity(0.14)
    }
}

private extension Place {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private extension AppUser {
    var homeCoordinate: CLLocationCoordinate2D? {
        guard let homeLatitude, let homeLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: homeLatitude, longitude: homeLongitude)
    }
}
