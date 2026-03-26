import SwiftUI
import FirebaseFirestore

struct PlaceListView: View {
    private enum ListSection: String, CaseIterable, Identifiable {
        case bucket = "버킷리스트"
        case history = "히스토리"

        var id: String { rawValue }
    }

    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService

    @StateObject private var viewModel = MapViewModel()
    @StateObject private var placeService = PlaceService()
    @StateObject private var visitRecordService = VisitRecordService()

    @State private var selectedSection: ListSection = .bucket
    @State private var placeToEdit: Place?
    @State private var placeToDelete: Place?
    @State private var visitRecords: [VisitRecord] = []
    @State private var recordToEdit: VisitRecord?
    @State private var recordToDelete: VisitRecord?
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
                } else if isCurrentSectionEmpty {
                    ContentUnavailableView(
                        selectedSection == .bucket ? "버킷리스트가 비어 있습니다" : "히스토리가 비어 있습니다",
                        systemImage: "list.bullet.rectangle",
                        description: Text(selectedSection == .bucket ? "지도에서 장소를 추가하면 여기에 표시됩니다." : "방문 기록을 남기면 여기에 표시됩니다.")
                    )
                } else {
                    List {
                        if selectedSection == .bucket {
                            ForEach(bucketPlaces) { place in
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

                                    Button("수정") {
                                        placeToEdit = place
                                    }
                                    .tint(.blue)
                                }
                            }
                        } else {
                            ForEach(visitRecords) { record in
                                if let place = placeByID[record.placeID] {
                                    NavigationLink {
                                        PlaceDetailView(place: place)
                                            .environmentObject(spaceService)
                                            .environmentObject(authService)
                                    } label: {
                                        VisitRecordRow(record: record)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        if record.createdBy == authService.currentUser?.id {
                                            Button("삭제", role: .destructive) {
                                                recordToDelete = record
                                            }

                                            Button("수정") {
                                                recordToEdit = record
                                            }
                                            .tint(.blue)
                                        }
                                    }
                                } else {
                                    VisitRecordRow(record: record)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(spaceService.activeSpace?.name ?? "리스트")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("구분", selection: $selectedSection) {
                        ForEach(ListSection.allCases) { section in
                            Text(section.rawValue).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            }
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
                    visitRecordListener?.remove()
                    visitRecordListener = nil
                    visitRecords = []
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
            .sheet(item: $recordToEdit) { record in
                if let place = placeByID[record.placeID] {
                    VisitRecordFormView(place: place, existingRecord: record)
                        .environmentObject(authService)
                } else {
                    Text("해당 장소를 찾을 수 없습니다.")
                }
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
            .alert("방문 기록을 삭제할까요?", isPresented: deleteRecordAlertBinding, presenting: recordToDelete) { record in
                Button("삭제", role: .destructive) {
                    deleteRecord(record)
                }
                Button("취소", role: .cancel) {
                    recordToDelete = nil
                }
            } message: { record in
                Text("\"\(record.title)\" 기록을 삭제합니다.")
            }
            .overlay {
                if placeService.isLoading || visitRecordService.isLoading {
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

    private var bucketPlaces: [Place] {
        viewModel.places
            .filter { !$0.isVisited }
            .sorted { $0.addedAt > $1.addedAt }
    }

    private var placeByID: [String: Place] {
        Dictionary(uniqueKeysWithValues: viewModel.places.map { ($0.id, $0) })
    }

    private var isCurrentSectionEmpty: Bool {
        switch selectedSection {
        case .bucket:
            return bucketPlaces.isEmpty
        case .history:
            return visitRecords.isEmpty
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

    private var deleteRecordAlertBinding: Binding<Bool> {
        Binding(
            get: { recordToDelete != nil },
            set: { newValue in
                if !newValue {
                    recordToDelete = nil
                }
            }
        )
    }

    private func listenForVisitRecords(spaceID: String) {
        visitRecordListener?.remove()
        visitRecordListener = visitRecordService.listenForSpaceRecords(spaceID: spaceID) { records in
            visitRecords = records
        }
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

    private func deleteRecord(_ record: VisitRecord) {
        Task {
            do {
                try await visitRecordService.deleteVisitRecord(record)
                recordToDelete = nil
            } catch {
            }
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
