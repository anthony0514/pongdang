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
    @State private var placeToEdit: Place?
    @State private var placeToDelete: Place?
    @State private var visitRecords: [VisitRecord] = []
    @State private var visitRecordListener: ListenerRegistration?
    @State private var searchableContentByPlaceID: [String: String] = [:]
    @State private var searchIndexBuildTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
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
            .navigationTitle("버킷리스트")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                bottomSearchField
            }
            .onAppear {
                if let space = spaceService.activeSpace {
                    viewModel.fetchPlaces(for: space.id)
                    listenForVisitRecords(spaceID: space.id)
                }
                scheduleSearchIndexRebuild()
            }
            .onChange(of: spaceService.activeSpace) { _, space in
                if let space {
                    viewModel.fetchPlaces(for: space.id)
                    listenForVisitRecords(spaceID: space.id)
                } else {
                    viewModel.places = []
                    visitRecords = []
                    searchableContentByPlaceID = [:]
                    searchIndexBuildTask?.cancel()
                    visitRecordListener?.remove()
                    visitRecordListener = nil
                }
            }
            .onChange(of: viewModel.places) { _, _ in
                scheduleSearchIndexRebuild()
            }
            .onChange(of: visitRecords) { _, _ in
                scheduleSearchIndexRebuild()
            }
            .onDisappear {
                searchIndexBuildTask?.cancel()
                visitRecordListener?.remove()
                visitRecordListener = nil
            }
            .sheet(item: $placeToEdit) { place in
                AddPlaceView(initialCoordinate: nil, placeToEdit: place)
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
            .overlay {
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
        }
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
                        Button {
                            navigationState.showPlaceOnMap(
                                placeID: place.id,
                                presentDetail: true,
                                compactDetailSheet: true
                            )
                        } label: {
                            PlaceListRow(place: place)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if canManage(place) {
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
                        place.tags.joined(separator: " "),
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
    let place: Place

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(place.category.accentColor.opacity(0.16))
                    .frame(width: 34, height: 34)

                Image(systemName: place.category.systemImageName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(place.category.accentColor)

                if place.isVisited {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.system(size: 6, weight: .black))
                                .foregroundStyle(.white)
                        )
                        .offset(x: 12, y: -12)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(place.name)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(place.address.isEmpty ? place.category.displayName : place.address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(place.category.displayName)
                    Text(place.isVisited ? "방문 완료" : "미방문")
                        .foregroundStyle(place.isVisited ? .green : .pink)
                }
                .font(.caption)
                .fontWeight(.semibold)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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
