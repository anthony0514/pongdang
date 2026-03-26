import SwiftUI
import FirebaseFirestore

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

        var id: String { rawValue }
    }

    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService

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

    var body: some View {
        NavigationStack {
            Group {
                if spaceService.activeSpace == nil {
                    ContentUnavailableView(
                        "스페이스가 없습니다",
                        systemImage: "person.3",
                        description: Text("먼저 스페이스를 만들거나 참여해 주세요.")
                    )
                } else {
                    List {
                        searchSection
                        filtersSection

                        if filteredPlaces.isEmpty {
                            ContentUnavailableView(
                                "표시할 장소가 없습니다",
                                systemImage: "list.bullet.rectangle",
                                description: Text(emptyStateDescription)
                            )
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        } else {
                            ForEach(filteredPlaces) { place in
                                NavigationLink {
                                    PlaceDetailView(place: place)
                                        .environmentObject(spaceService)
                                        .environmentObject(authService)
                                } label: {
                                    PlaceListRow(place: place)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("버킷리스트")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let space = spaceService.activeSpace {
                    viewModel.fetchPlaces(for: space.id)
                    listenForVisitRecords(spaceID: space.id)
                }
            }
            .onChange(of: spaceService.activeSpace) { _, space in
                if let space {
                    viewModel.fetchPlaces(for: space.id)
                    listenForVisitRecords(spaceID: space.id)
                } else {
                    viewModel.places = []
                    visitRecords = []
                    visitRecordListener?.remove()
                    visitRecordListener = nil
                }
            }
            .onDisappear {
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

    private var searchSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("장소 검색", text: $searchText)
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
            .padding(.vertical, 4)
        }
    }

    private var filtersSection: some View {
        Section {
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

                    Spacer()

                    Menu {
                        ForEach(SortOption.allCases) { option in
                            Button {
                                selectedSortOption = option
                            } label: {
                                if selectedSortOption == option {
                                    Label(option.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(option.rawValue)
                                }
                            }
                        }
                    } label: {
                        Text(selectedSortOption.rawValue)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(.vertical, 4)
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
                let relatedVisitRecords = visitRecords.filter { $0.placeID == place.id }
                let visitRecordText = relatedVisitRecords
                    .flatMap { [$0.title, $0.body ?? ""] }
                    .joined(separator: "\n")

                let fields = [
                    place.name,
                    place.address,
                    place.category.rawValue,
                    place.memo ?? "",
                    place.tags.joined(separator: " "),
                    visitRecordText
                ]

                return fields
                    .joined(separator: "\n")
                    .lowercased()
                    .contains(normalizedQuery)
            }
        }

        switch selectedSortOption {
        case .newest:
            return searchFiltered.sorted { $0.addedAt > $1.addedAt }
        case .oldest:
            return searchFiltered.sorted { $0.addedAt < $1.addedAt }
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
                try await placeService.deletePlace(id: place.id)
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
}

private struct PlaceListRow: View {
    let place: Place

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(place.isVisited ? Color.green : Color.pink)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 6) {
                Text(place.name)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(place.address.isEmpty ? place.category.rawValue : place.address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(place.category.rawValue)
                    Text(place.isVisited ? "방문 완료" : "미방문")
                        .foregroundStyle(place.isVisited ? .green : .pink)
                }
                .font(.caption)
                .fontWeight(.semibold)
            }
        }
        .padding(.vertical, 4)
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
