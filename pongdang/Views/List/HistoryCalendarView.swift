import SwiftUI
import FirebaseFirestore

struct HistoryCalendarView: View {
    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService

    @StateObject private var viewModel = MapViewModel()
    @StateObject private var visitRecordService = VisitRecordService()

    @State private var visitRecords: [VisitRecord] = []
    @State private var selectedDate = Date()
    @State private var visitRecordListener: ListenerRegistration?

    var body: some View {
        NavigationStack {
            Group {
                if spaceService.activeSpace == nil {
                    ContentUnavailableView(
                        "스페이스가 없습니다",
                        systemImage: "calendar",
                        description: Text("먼저 스페이스를 만들거나 참여해 주세요.")
                    )
                } else {
                    List {
                        Section {
                            DatePicker(
                                "날짜 선택",
                                selection: $selectedDate,
                                displayedComponents: .date
                            )
                            .datePickerStyle(.graphical)
                        }

                        Section(selectedDateTitle) {
                            if recordsForSelectedDate.isEmpty {
                                Text("선택한 날짜에는 방문 기록이 없습니다.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(recordsForSelectedDate) { record in
                                    if let place = placeByID[record.placeID] {
                                        NavigationLink {
                                            PlaceDetailView(place: place)
                                                .environmentObject(spaceService)
                                                .environmentObject(authService)
                                        } label: {
                                            VisitRecordRow(record: record)
                                        }
                                    } else {
                                        VisitRecordRow(record: record)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("캘린더")
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
                    visitRecords = []
                    visitRecordListener?.remove()
                    visitRecordListener = nil
                }
            }
            .onDisappear {
                visitRecordListener?.remove()
                visitRecordListener = nil
            }
        }
    }

    private var placeByID: [String: Place] {
        Dictionary(uniqueKeysWithValues: viewModel.places.map { ($0.id, $0) })
    }

    private var recordsForSelectedDate: [VisitRecord] {
        visitRecords.filter { Calendar.current.isDate($0.visitedAt, inSameDayAs: selectedDate) }
    }

    private var selectedDateTitle: String {
        Self.dateFormatter.string(from: selectedDate)
    }

    private func listenForVisitRecords(spaceID: String) {
        visitRecordListener?.remove()
        visitRecordListener = visitRecordService.listenForSpaceRecords(spaceID: spaceID) { records in
            visitRecords = records
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()
}
