import SwiftUI
import FirebaseFirestore
import CoreLocation

struct PlaceListView: View {
    private enum StatusFilter: String, CaseIterable, Identifiable {
        case all = "모두"
        case visited = "방문 완료"
        case unvisited = "미방문"

        var id: String { rawValue }
    }

    private enum SortOption: String, CaseIterable, Identifiable {
        case newest = "최신 순"
        case oldest = "오래된 순"
        case distance = "가까운 순"
        case name = "이름순"

        var id: String { rawValue }
    }

    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var navigationState: AppNavigationState
    @EnvironmentObject var appLocationStore: AppLocationStore

    @StateObject private var viewModel = MapViewModel()
    @StateObject private var placeService = PlaceService()
    @StateObject private var visitRecordService = VisitRecordService()

    @State private var selectedStatusFilter: StatusFilter = .all
    @State private var selectedSortOption: SortOption = .newest
    @State private var searchText = ""
    @State private var isSelectionMode = false
    @State private var selectedPlaceIDs: Set<String> = []
    @State private var placeToEdit: Place?
    @State private var placeToCopy: Place?
    @State private var placeToDelete: Place?
    @State private var showingBatchShare = false
    @State private var showingBatchDeleteAlert = false
    @State private var visitRecords: [VisitRecord] = []
    @State private var visitRecordListener: ListenerRegistration?
    @State private var searchableContentByPlaceID: [String: String] = [:]
    @State private var searchIndexBuildTask: Task<Void, Never>?

    var body: some View {
        navigationContent
    }

    private var navigationContent: some View {
        NavigationStack {
            contentView
        }
    }

    private var contentView: some View {
        baseContent
            .navigationTitle("버킷리스트")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { selectionToolbar }
            .safeAreaInset(edge: .bottom) {
                bottomInsetContent
            }
            .sheet(item: $placeToEdit) { place in
                AddPlaceView(initialCoordinate: nil, placeToEdit: place)
                    .environmentObject(spaceService)
                    .environmentObject(authService)
            }
            .sheet(item: $placeToCopy) { place in
                CopyPlaceToSpaceView(place: place)
                    .environmentObject(spaceService)
                    .environmentObject(authService)
            }
            .sheet(isPresented: $showingBatchShare) {
                BatchSharePlacesView(places: selectedPlaces) {
                    clearSelectionMode()
                }
                .environmentObject(spaceService)
                .environmentObject(authService)
            }
            .alert("장소를 삭제할까요?", isPresented: deleteAlertBinding, presenting: placeToDelete) { place in
                Button("삭제", role: .destructive) {
                    deletePlace(place)
                }
                Button("취소", role: .cancel) {
                    placeToDelete = nil
                }
            } message: { place in
                Text("\"\(place.name)\"을(를) 삭제합니다.")
            }
            .alert("선택한 장소를 삭제할까요?", isPresented: $showingBatchDeleteAlert) {
                Button("삭제", role: .destructive) {
                    deleteSelectedPlaces()
                }
                Button("취소", role: .cancel) {
                }
            } message: {
                Text("\(selectedManageablePlaces.count)개 장소와 해당 방문 기록이 삭제됩니다.")
            }
            .overlay { loadingOverlay }
            .overlay(alignment: .bottom) { selectionOverlay }
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: isSelectionMode)
            .animation(.spring(response: 0.24, dampingFraction: 0.9), value: selectedPlaceIDs)
            .onAppear(perform: handleOnAppear)
            .onChange(of: spaceService.activeSpace) { _, space in
                handleActiveSpaceChange(space)
            }
            .onChange(of: viewModel.places) { _, _ in
                scheduleSearchIndexRebuild()
                pruneSelection()
            }
            .onChange(of: visitRecords) { _, _ in
                scheduleSearchIndexRebuild()
            }
            .onDisappear(perform: handleOnDisappear)
    }

    private var baseContent: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            if spaceService.activeSpace == nil {
                ContentUnavailableView(
                    "스페이스가 없습니다",
                    systemImage: "person.3",
                    description: Text("먼저 스페이스를 만들거나 참여해 주세요.")
                )
            } else {
                VStack(spacing: 12) {
                    filtersSection
                    placeListSection
                }
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var bottomInsetContent: some View {
        if spaceService.activeSpace != nil {
            if !isSelectionMode {
                bottomSearchField
            } else {
                bottomBarPlaceholder
            }
        }
    }

    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isSelectionMode {
                Button("취소") {
                    clearSelectionMode()
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            if isSelectionMode {
                Button(allSelectablePlacesSelected ? "해제" : "전체") {
                    toggleSelectAll()
                }
            }
        }
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        if placeService.isLoading {
            ZStack {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                ProgressView()
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelectionMode {
            selectionActionBar
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func handleOnAppear() {
        if let space = spaceService.activeSpace {
            viewModel.fetchPlaces(for: space.id)
            listenForVisitRecords(spaceID: space.id)
        }
        scheduleSearchIndexRebuild()
    }

    private func handleActiveSpaceChange(_ space: Space?) {
        if let space {
            viewModel.fetchPlaces(for: space.id)
            listenForVisitRecords(spaceID: space.id)
            pruneSelection()
        } else {
            viewModel.places = []
            visitRecords = []
            searchableContentByPlaceID = [:]
            clearSelectionMode()
            searchIndexBuildTask?.cancel()
            visitRecordListener?.remove()
            visitRecordListener = nil
        }
    }

    private func handleOnDisappear() {
        searchIndexBuildTask?.cancel()
        visitRecordListener?.remove()
        visitRecordListener = nil
    }

    private var bottomSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("장소 검색", text: $searchText)
                .onChange(of: searchText) { _, newValue in
                    searchText = InputSanitizer.sanitize(newValue, as: .search)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var bottomBarPlaceholder: some View {
        Color.clear
            .frame(height: 44)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
    }

    private var selectionActionBar: some View {
        ZStack {
            if let deleteDisabledReason {
                Text(deleteDisabledReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 88)
            }

            HStack(spacing: 10) {
                Text(selectionSummaryText)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button {
                    showingBatchShare = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedPlaces.isEmpty ? Color(.tertiaryLabel) : Color(hex: "2F7FB8"))
                .disabled(selectedPlaces.isEmpty)

                Button {
                    showingBatchDeleteAlert = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canDeleteSelectedPlaces ? .red : Color(.tertiaryLabel))
                .disabled(!canDeleteSelectedPlaces)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
    }

    private var filtersSection: some View {
        VStack(spacing: 12) {
            Picker("보기 기준", selection: $selectedStatusFilter) {
                ForEach(StatusFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("정렬 기준")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 8)

                Spacer()

                Picker("정렬 기준", selection: $selectedSortOption) {
                    ForEach(SortOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 118, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.45), lineWidth: 0.6)
        )
        .padding(.horizontal, 16)
    }

    private var placeListSection: some View {
        Group {
            if filteredPlaces.isEmpty {
                ContentUnavailableView(
                    "표시할 장소가 없습니다",
                    systemImage: "list.bullet.rectangle",
                    description: Text(emptyStateDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 16)
            } else {
                List {
                    ForEach(Array(filteredPlaces.enumerated()), id: \.element.id) { index, place in
                        PlaceListRow(
                            place: place,
                            isSelectionMode: isSelectionMode,
                            isSelected: selectedPlaceIDs.contains(place.id),
                            isManageable: canManage(place)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handlePlaceTap(place)
                        }
                        .onLongPressGesture(minimumDuration: 0.35) {
                            beginSelection(with: place)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if canManage(place) && !isSelectionMode {
                                Button("공유") {
                                    placeToCopy = place
                                }
                                .tint(Color(hex: "5B9BD5"))

                                Button("삭제", role: .destructive) {
                                    placeToDelete = place
                                }
                                .tint(.red)

                                Button("수정") {
                                    placeToEdit = place
                                }
                                .tint(Color(hex: "2F7FB8"))
                            }
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .listRowBackground(Color(.secondarySystemGroupedBackground))
                        .listRowSeparator(index == filteredPlaces.count - 1 ? .hidden : .visible)
                        .listSectionSeparator(.hidden, edges: index == 0 ? .top : [])
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 16)
            }
        }
    }

    private var selectedManageablePlaces: [Place] {
        viewModel.places.filter { selectedPlaceIDs.contains($0.id) && canManage($0) }
    }

    private var selectedPlaces: [Place] {
        viewModel.places.filter { selectedPlaceIDs.contains($0.id) }
    }

    private var manageableFilteredPlaces: [Place] {
        filteredPlaces
    }

    private var allSelectablePlacesSelected: Bool {
        !manageableFilteredPlaces.isEmpty && manageableFilteredPlaces.allSatisfy { selectedPlaceIDs.contains($0.id) }
    }

    private var canDeleteSelectedPlaces: Bool {
        !selectedPlaces.isEmpty && selectedPlaces.allSatisfy(canManage)
    }

    private var deleteDisabledReason: String? {
        guard !selectedPlaces.isEmpty, !canDeleteSelectedPlaces else { return nil }
        return "삭제 권한이 없는 장소가 포함되어 있어요"
    }

    private var selectionSummaryText: String {
        if selectedPlaces.isEmpty {
            return "선택된 장소가 없습니다"
        }
        return "\(selectedPlaces.count)개 선택됨"
    }

    private var filteredPlaces: [Place] {
        let statusFiltered = viewModel.places.filter { place in
            switch selectedStatusFilter {
            case .all:
                return true
            case .visited:
                return place.isVisited
            case .unvisited:
                return !place.isVisited
            }
        }

        let normalizedQuery = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let searchFiltered: [Place]
        if normalizedQuery.isEmpty {
            searchFiltered = statusFiltered
        } else {
            searchFiltered = statusFiltered.filter { place in
                searchableContentByPlaceID[place.id, default: ""].contains(normalizedQuery)
            }
        }

        switch selectedSortOption {
        case .newest:
            return searchFiltered.sorted { $0.addedAt > $1.addedAt }
        case .oldest:
            return searchFiltered.sorted { $0.addedAt < $1.addedAt }
        case .distance:
            guard let userLocation = appLocationStore.currentCoordinate else {
                return searchFiltered.sorted { $0.addedAt > $1.addedAt }
            }

            let currentLocation = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
            return searchFiltered.sorted { lhs, rhs in
                let lhsDistance = CLLocation(latitude: lhs.latitude, longitude: lhs.longitude).distance(from: currentLocation)
                let rhsDistance = CLLocation(latitude: rhs.latitude, longitude: rhs.longitude).distance(from: currentLocation)

                if lhsDistance == rhsDistance {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }

                return lhsDistance < rhsDistance
            }
        case .name:
            return searchFiltered.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    private func canManage(_ place: Place) -> Bool {
        let currentUserID = authService.currentUser?.id
        let ownerID = spaceService.activeSpace?.createdBy
        return currentUserID == place.addedBy || currentUserID == ownerID
    }

    private func handlePlaceTap(_ place: Place) {
        if isSelectionMode {
            toggleSelection(for: place)
            return
        }

        navigationState.showPlaceOnMap(
            placeID: place.id,
            presentDetail: true,
            compactDetailSheet: true
        )
    }

    private func beginSelection(with place: Place) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            if !isSelectionMode {
                isSelectionMode = true
            }
            toggleSelection(for: place)
        }
    }

    private func toggleSelection(for place: Place) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            if selectedPlaceIDs.contains(place.id) {
                selectedPlaceIDs.remove(place.id)
            } else {
                selectedPlaceIDs.insert(place.id)
            }

            if selectedPlaceIDs.isEmpty {
                isSelectionMode = false
            }
        }
    }

    private func toggleSelectAll() {
        let manageableIDs = Set(manageableFilteredPlaces.map(\.id))
        guard !manageableIDs.isEmpty else { return }

        if allSelectablePlacesSelected {
            selectedPlaceIDs.subtract(manageableIDs)
        } else {
            selectedPlaceIDs.formUnion(manageableIDs)
        }

        if selectedPlaceIDs.isEmpty {
            isSelectionMode = false
        } else {
            isSelectionMode = true
        }
    }

    private func pruneSelection() {
        let availableIDs = Set(viewModel.places.map(\.id))
        selectedPlaceIDs = selectedPlaceIDs.intersection(availableIDs)
        if selectedPlaceIDs.isEmpty {
            isSelectionMode = false
        }
    }

    private func clearSelectionMode() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
            isSelectionMode = false
            selectedPlaceIDs.removeAll()
        }
    }

    private var emptyStateDescription: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "검색 결과가 없습니다."
        }

        switch selectedStatusFilter {
        case .all:
            return "지도에서 장소를 추가하면 여기에 표시됩니다."
        case .visited:
            return "방문 완료한 장소가 아직 없습니다."
        case .unvisited:
            return "미방문 장소가 없습니다."
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { placeToDelete != nil },
            set: { newValue in
                if !newValue {
                    placeToDelete = nil
                }
            }
        )
    }

    private func deletePlace(_ place: Place) {
        Task {
            do {
                try await placeService.deletePlace(
                    id: place.id,
                    requestedBy: authService.currentUser?.id ?? ""
                )
                placeToDelete = nil
            } catch {
            }
        }
    }

    private func deleteSelectedPlaces() {
        let selectedIDs = selectedPlaces.map(\.id)
        guard !selectedIDs.isEmpty else { return }

        Task {
            do {
                try await placeService.deletePlaces(
                    ids: selectedIDs,
                    requestedBy: authService.currentUser?.id ?? ""
                )
                clearSelectionMode()
            } catch {
            }
        }
    }

    private func listenForVisitRecords(spaceID: String) {
        visitRecordListener?.remove()
        visitRecordListener = visitRecordService.listenForSpaceRecords(spaceID: spaceID) { records in
            visitRecords = records
        }
    }

    private func scheduleSearchIndexRebuild() {
        searchIndexBuildTask?.cancel()

        let places = viewModel.places
        let records = visitRecords

        searchIndexBuildTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }

            let index = await buildSearchIndex(places: places, records: records)
            guard !Task.isCancelled else { return }

            searchableContentByPlaceID = index
        }
    }

    private func buildSearchIndex(places: [Place], records: [VisitRecord]) async -> [String: String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let visitRecordTextByPlaceID = Dictionary(grouping: records, by: \.placeID)
                    .mapValues { records in
                        records
                            .flatMap { [$0.title, $0.body ?? ""] }
                            .joined(separator: "\n")
                    }

                let index = Dictionary(uniqueKeysWithValues: places.map { place in
                    let fields = [
                        place.name,
                        place.address,
                        place.category.displayName,
                        place.memo ?? "",
                        visitRecordTextByPlaceID[place.id] ?? ""
                    ]

                    return (place.id, fields.joined(separator: "\n").lowercased())
                })

                continuation.resume(returning: index)
            }
        }
    }
}

private struct PlaceListRow: View {
    private static let iconSize: CGFloat = 34
    private static let iconSymbolSize: CGFloat = 14
    private static let statusBadgeSize: CGFloat = 12

    let place: Place
    let isSelectionMode: Bool
    let isSelected: Bool
    let isManageable: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if isSelectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(selectionIndicatorColor)
                        .scaleEffect(isSelected ? 1 : 0.92)
                        .transition(.scale(scale: 0.72).combined(with: .opacity))
                }
            }
            .frame(width: isSelectionMode ? 24 : 0)
            .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isSelectionMode)
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isSelected)

            ZStack {
                Circle()
                    .fill(place.category.accentColor.opacity(0.16))
                    .frame(width: Self.iconSize, height: Self.iconSize)

                Image(systemName: place.category.systemImageName)
                    .font(.system(size: Self.iconSymbolSize, weight: .semibold))
                    .foregroundStyle(place.category.accentColor)

                if place.isVisited {
                    Circle()
                        .fill(Color.green)
                        .frame(width: Self.statusBadgeSize, height: Self.statusBadgeSize)
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.system(size: 6, weight: .black))
                                .foregroundStyle(.white)
                        )
                        .offset(x: Self.iconSize * 0.35, y: -Self.iconSize * 0.35)
                }
            }
            .frame(width: Self.iconSize, height: Self.iconSize)
            .padding(.leading, isSelectionMode ? 0 : -16)

            VStack(alignment: .leading, spacing: 6) {
                Text(place.name)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(place.address.isEmpty ? place.category.displayName : place.address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var selectionIndicatorColor: Color {
        return isSelected ? Color(hex: "2F7FB8") : Color(.secondaryLabel)
    }
}

struct VisitRecordRow: View {
    let record: VisitRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 6) {
                Text(record.placeName)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(record.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    Text(Self.dateFormatter.string(from: record.visitedAt))
                    Text("\(record.rating)점")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()
}
