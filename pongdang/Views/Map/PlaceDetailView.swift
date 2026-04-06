import SwiftUI
import CoreLocation
import FirebaseFirestore

struct PlaceDetailView: View {
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
    @EnvironmentObject var navigationState: AppNavigationState
    @StateObject private var placeService = PlaceService()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("preferredExternalMapApp") private var preferredExternalMapAppRawValue = ExternalMapApp.kakao.rawValue

    @State private var showingEdit = false
    @State private var showingDeleteAlert = false
    @State private var showingVisitRecordForm = false
    @State private var addedByName = "불러오는 중..."
    @State private var visitRecords: [VisitRecord] = []
    @State private var authorNamesByUserID: [String: String] = [:]
    @State private var recordToEdit: VisitRecord?
    @State private var recordToDelete: VisitRecord?

    @StateObject private var visitRecordService = VisitRecordService()
    @State private var visitRecordListener: ListenerRegistration?

    let place: Place
    let showsFloatingWriteButton: Bool

    var body: some View {
        NavigationStack {
            detailContent
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
            .task(id: visitRecords.map(\.createdBy).joined(separator: "|")) {
                await loadAuthorNamesIfNeeded()
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
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()

                    if showsFloatingWriteButton {
                        Button {
                            showingVisitRecordForm = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 24, weight: .bold))
                                .frame(width: 58, height: 58)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("방문 기록 추가")
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .animation(.easeInOut(duration: 0.18), value: showsFloatingWriteButton)
            }
        }
    }

    private var detailContent: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    tagSection
                    memoSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                .listRowSeparator(.hidden)
            }

            Section {
                if visitRecords.isEmpty {
                    Text("아직 남겨진 방문 기록이 없습니다.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                } else {
                    ForEach(visitRecords) { record in
                        VisitRecordListRow(
                            record: record,
                            authorName: authorName(for: record)
                        )
                            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                            .listRowSeparator(.visible)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if record.createdBy == authService.currentUser?.id {
                                    Button("삭제", role: .destructive) {
                                        recordToDelete = record
                                    }
                                    .tint(.red)
                                }

                                Button(editActionTitle(for: record)) {
                                    recordToEdit = record
                                }
                                .tint(Color(hex: "2F7FB8"))
                            }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(place.category.rawValue)
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
                .clipShape(Capsule())

            Text(visitStatusText)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(visitStatusColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(visitStatusBackground)
                .clipShape(Capsule())

            Spacer()

            Button(action: openInPreferredMapApp) {
                Image(systemName: "link")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(preferredExternalMapApp.title)에서 열기")
        }
    }

    @ViewBuilder
    private var tagSection: some View {
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
    }

    @ViewBuilder
    private var memoSection: some View {
        if let memo = place.memo, !memo.isEmpty {
            Text(memo)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private func authorName(for record: VisitRecord) -> String? {
        if record.createdBy == authService.currentUser?.id {
            return authService.currentUser?.name
        }

        return authorNamesByUserID[record.createdBy]
    }

    private func loadAuthorNamesIfNeeded() async {
        let userIDs = Set(
            visitRecords
                .map(\.createdBy)
                .filter { $0 != authService.currentUser?.id && authorNamesByUserID[$0] == nil }
        )

        guard !userIDs.isEmpty else { return }

        for userID in userIDs {
            do {
                let snapshot = try await Firestore.firestore()
                    .collection("users")
                    .document(userID)
                    .getDocument()

                if let name = snapshot.data()?["name"] as? String, !name.isEmpty {
                    authorNamesByUserID[userID] = name
                } else {
                    authorNamesByUserID[userID] = "알 수 없음"
                }
            } catch {
                authorNamesByUserID[userID] = "알 수 없음"
            }
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

    private var preferredExternalMapApp: ExternalMapApp {
        ExternalMapApp(rawValue: preferredExternalMapAppRawValue) ?? .kakao
    }

    private var visitStatusText: String {
        visitRecords.isEmpty ? "미방문" : "방문 완료"
    }

    private var visitStatusColor: Color {
        visitRecords.isEmpty ? .gray : .green
    }

    private var visitStatusBackground: Color {
        visitStatusColor.opacity(0.14)
    }

    private func openInPreferredMapApp() {
        let preferredApp: PreferredMapApp = preferredExternalMapApp == .kakao ? .kakao : .naver
        if let url = ExternalMapOpener.resolvedURL(for: place, preferredApp: preferredApp) {
            openURL(url)
        }
    }

    private func editActionTitle(for record: VisitRecord) -> String {
        record.createdBy == authService.currentUser?.id ? "수정" : "날짜 수정"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()
}

private struct VisitRecordListRow: View {
    let record: VisitRecord
    let authorName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.title)
                    .font(.headline)

                Spacer()

                Text(Self.dateFormatter.string(from: record.visitedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(record.rating)점")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Capsule())
            }

            if let body = record.body, !body.isEmpty {
                HStack(alignment: .bottom, spacing: 12) {
                    Text(body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    if let authorName, !authorName.isEmpty {
                        Text(authorName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            } else if let authorName, !authorName.isEmpty {
                HStack {
                    Spacer()

                    Text(authorName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
