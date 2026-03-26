import SwiftUI
import CoreLocation
import FirebaseFirestore

struct PlaceDetailView: View {
    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService
    @StateObject private var placeService = PlaceService()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showingEdit = false
    @State private var showingDeleteAlert = false
    @State private var showingVisitRecordForm = false
    @State private var addedByName = "불러오는 중..."
    @State private var visitRecords: [VisitRecord] = []
    @State private var recordToEdit: VisitRecord?
    @State private var recordToDelete: VisitRecord?

    @StateObject private var visitRecordService = VisitRecordService()
    @State private var visitRecordListener: ListenerRegistration?

    let place: Place

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Text(place.category.rawValue)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(Capsule())

                        Text(visitRecords.isEmpty ? "미방문" : "방문 완료")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(visitRecords.isEmpty ? .gray : .green)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background((visitRecords.isEmpty ? Color.gray : Color.green).opacity(0.14))
                            .clipShape(Capsule())

                        Spacer()
                    }

                    if !place.tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(place.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.subheadline)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color(.secondarySystemBackground))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }

                    if let memo = place.memo {
                        Text(memo)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()

                    Text("추가: \(addedByName)")
                        .font(.subheadline)
                    Text(Self.dateFormatter.string(from: place.addedAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button(visitRecords.isEmpty ? "방문 기록 작성" : "방문 추가 기록") {
                        showingVisitRecordForm = true
                    }
                    .buttonStyle(.borderedProminent)

                    Button("지도 앱에서 열기") {
                        openInKakaoMap()
                    }
                    .buttonStyle(.bordered)

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("방문 기록")
                            .font(.headline)

                        if visitRecords.isEmpty {
                            Text("아직 남겨진 방문 기록이 없습니다.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(visitRecords) { record in
                                VisitRecordCard(
                                    record: record,
                                    isOwnedByCurrentUser: record.createdBy == authService.currentUser?.id,
                                    onEdit: {
                                        recordToEdit = record
                                    },
                                    onDelete: {
                                        recordToDelete = record
                                    }
                                )
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(Color.clear)
            .navigationTitle(place.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("편집") {
                            showingEdit = true
                        }

                        Button("삭제", role: .destructive) {
                            showingDeleteAlert = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("삭제하시겠어요?", isPresented: $showingDeleteAlert) {
                Button("삭제", role: .destructive) {
                    deletePlace()
                }
                Button("취소", role: .cancel) {
                }
            }
            .sheet(isPresented: $showingEdit) {
                AddPlaceView(initialCoordinate: nil, placeToEdit: place)
                    .environmentObject(spaceService)
                    .environmentObject(authService)
            }
            .sheet(isPresented: $showingVisitRecordForm) {
                VisitRecordFormView(place: place, existingRecord: nil)
                    .environmentObject(authService)
            }
            .sheet(item: $recordToEdit) { record in
                VisitRecordFormView(place: place, existingRecord: record)
                    .environmentObject(authService)
            }
            .task(id: place.addedBy) {
                await loadAddedByName()
            }
            .task(id: place.id) {
                listenForVisitRecords()
            }
            .onDisappear {
                visitRecordListener?.remove()
                visitRecordListener = nil
            }
            .alert("방문 기록을 삭제할까요?", isPresented: deleteVisitRecordAlertBinding, presenting: recordToDelete) { record in
                Button("삭제", role: .destructive) {
                    deleteVisitRecord(record)
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

    private func loadAddedByName() async {
        if place.addedBy == authService.currentUser?.id, let currentUserName = authService.currentUser?.name {
            addedByName = currentUserName
            return
        }

        do {
            let snapshot = try await Firestore.firestore()
                .collection("users")
                .document(place.addedBy)
                .getDocument()

            if let name = snapshot.data()?["name"] as? String, !name.isEmpty {
                addedByName = name
            } else {
                addedByName = "알 수 없음"
            }
        } catch {
            addedByName = "알 수 없음"
        }
    }

    private func listenForVisitRecords() {
        visitRecordListener?.remove()
        visitRecordListener = visitRecordService.listenForPlaceRecords(placeID: place.id) { records in
            visitRecords = records
        }
    }

    private var deleteVisitRecordAlertBinding: Binding<Bool> {
        Binding(
            get: { recordToDelete != nil },
            set: { newValue in
                if !newValue {
                    recordToDelete = nil
                }
            }
        )
    }

    private func deleteVisitRecord(_ record: VisitRecord) {
        Task {
            do {
                try await visitRecordService.deleteVisitRecord(record)
                recordToDelete = nil
            } catch {
            }
        }
    }

    private func deletePlace() {
        Task {
            do {
                try await placeService.deletePlace(id: place.id)
                dismiss()
            } catch {
            }
        }
    }

    private func openInKakaoMap() {
        guard let url = URL(string: "kakaomap://look?p=\(place.latitude),\(place.longitude)") else {
            return
        }
        openURL(url)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()
}

private struct VisitRecordCard: View {
    let record: VisitRecord
    let isOwnedByCurrentUser: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title)
                        .font(.headline)

                    Text(Self.dateFormatter.string(from: record.visitedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(record.rating)점")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Capsule())
            }

            if let body = record.body, !body.isEmpty {
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if isOwnedByCurrentUser {
                HStack(spacing: 12) {
                    Button("수정", action: onEdit)
                    Button("삭제", role: .destructive, action: onDelete)
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .pondangGlassCard(cornerRadius: 18)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()
}
