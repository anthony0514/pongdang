import SwiftUI
import CoreLocation
import FirebaseFirestore

struct PlaceDetailView: View {
    private enum ExternalMapApp: String {
        case apple
        case kakao
        case naver

        var title: String {
            switch self {
            case .apple:
                return "지도"
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
    @State private var showingCopyToSpace = false
    @State private var showingDeleteAlert = false
    @State private var showingVisitRecordForm = false
    @State private var selectedCategory: PlaceCategory
    @State private var addedByName = "불러오는 중..."
    @State private var visitRecords: [VisitRecord] = []
    @State private var authorNamesByUserID: [String: String] = [:]
    @State private var selectedVisit: VisitRecord?

    @StateObject private var visitRecordService = VisitRecordService()
    @State private var visitRecordListener: ListenerRegistration?

    let place: Place

    init(place: Place) {
        self.place = place
        _selectedCategory = State(initialValue: place.category)
    }

    var body: some View {
        NavigationStack {
            detailContent
            .background(Color.clear)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    titleView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    categoryMenuButton
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(preferredExternalMapApp.title + "에서 열기") {
                            openInPreferredMapApp()
                        }

                        if canManagePlace {
                            Button("다른 스페이스에 공유") {
                                showingCopyToSpace = true
                            }

                            Button("편집") {
                                showingEdit = true
                            }

                            Button("삭제", role: .destructive) {
                                showingDeleteAlert = true
                            }
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
            .sheet(isPresented: $showingCopyToSpace) {
                CopyPlaceToSpaceView(place: place)
                    .environmentObject(spaceService)
                    .environmentObject(authService)
            }
            .sheet(isPresented: $showingVisitRecordForm) {
                VisitRecordFormView(place: place)
                    .environmentObject(authService)
            }
            .navigationDestination(item: $selectedVisit) { visit in
                VisitDetailView(visit: visit)
                    .environmentObject(authService)
            }
            .task(id: place.addedBy) {
                await loadAddedByName()
            }
            .onChange(of: place.category) { _, newCategory in
                selectedCategory = newCategory
            }
            .task(id: place.id) {
                listenForVisitRecords()
            }
            .task(id: visitRecords.flatMap(\.participantIDs).joined(separator: "|")) {
                await loadAuthorNamesIfNeeded()
            }
            .onDisappear {
                visitRecordListener?.remove()
                visitRecordListener = nil
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
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
    }

    private var detailContent: some View {
        List {
            if hasSupplementaryContent {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        memoSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listSectionSeparator(.hidden)
                }
            }

            Section {
                if let errorMessage = visitRecordService.errorMessage, !errorMessage.isEmpty {
                    Text("방문 기록을 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else if visitRecords.isEmpty {
                    Text("아직 남겨진 방문 기록이 없습니다.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(visitRecords) { record in
                        Button {
                            selectedVisit = record
                        } label: {
                            VisitRecordListRow(
                                record: record,
                                participantNames: participantNames(for: record)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                        // Lines only between rows: none above the first or below the last.
                        .listRowSeparator(.hidden, edges: .top)
                        .listRowSeparator(record.id == visitRecords.last?.id ? .hidden : .visible, edges: .bottom)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.plain)
        // Let the sheet's translucent material show through.
        .scrollContentBackground(.hidden)
    }

    private var hasSupplementaryContent: Bool {
        (place.memo?.isEmpty) == false
    }

    private var titleView: some View {
        HStack(spacing: 8) {
            Image(systemName: visitRecords.isEmpty ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(visitRecords.isEmpty ? Color(.secondaryLabel) : Color.green)

            Text(place.name)
                .font(.headline)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var categoryMenuButton: some View {
        Menu {
            ForEach(PlaceCategory.allCases, id: \.self) { category in
                Button {
                    updateCategory(to: category)
                } label: {
                    HStack {
                        Text(category.displayName)
                        if category == selectedCategory {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(!canManagePlace || category == selectedCategory)
            }
        } label: {
            Image(systemName: selectedCategory.systemImageName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(selectedCategory.accentColor)
                .frame(width: 36, height: 36)
        }
        .accessibilityLabel("카테고리")
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
                addedByName = place.addedBy == "guest-user" ? "익명" : "알 수 없음"
            }
        } catch {
            addedByName = place.addedBy == "guest-user" ? "익명" : "알 수 없음"
        }
    }

    private func listenForVisitRecords() {
        visitRecordListener?.remove()
        visitRecordListener = visitRecordService.listenForPlaceRecords(spaceID: place.spaceID, placeID: place.id) { records in
            visitRecords = records
        }
    }

    private func participantNames(for record: VisitRecord) -> [String] {
        record.participantIDs.compactMap { userID in
            if userID == authService.currentUser?.id {
                return authService.currentUser?.name
            }
            return authorNamesByUserID[userID]
        }
    }

    private func loadAuthorNamesIfNeeded() async {
        var known = authorNamesByUserID
        if let currentUserID = authService.currentUser?.id {
            known[currentUserID] = ""
        }
        let loaded = await UserNameLoader.loadNames(
            for: visitRecords.flatMap(\.participantIDs),
            excluding: known
        )
        authorNamesByUserID.merge(loaded) { current, _ in current }
    }

    private var canManagePlace: Bool {
        let currentUserID = authService.currentUser?.id
        let ownerID = spaceService.activeSpace?.createdBy
        return currentUserID == place.addedBy || currentUserID == ownerID
    }

    private func deletePlace() {
        Task {
            do {
                try await placeService.deletePlace(
                    id: place.id,
                    requestedBy: authService.currentUser?.id ?? ""
                )
                dismiss()
            } catch {
            }
        }
    }

    private func updateCategory(to category: PlaceCategory) {
        guard canManagePlace, category != selectedCategory else { return }

        Task {
            do {
                try await placeService.updatePlace(
                    Place(
                        id: place.id,
                        spaceID: place.spaceID,
                        name: place.name,
                        address: place.address,
                        latitude: place.latitude,
                        longitude: place.longitude,
                        category: category,
                        memo: place.memo,
                        sourceURL: place.sourceURL,
                        addedBy: place.addedBy,
                        addedAt: place.addedAt,
                        isVisited: place.isVisited
                    ),
                    requestedBy: authService.currentUser?.id ?? ""
                )
                selectedCategory = category
            } catch {
            }
        }
    }

    private var preferredExternalMapApp: ExternalMapApp {
        ExternalMapApp(rawValue: preferredExternalMapAppRawValue) ?? .kakao
    }

    private func openInPreferredMapApp() {
        let preferredApp: PreferredMapApp
        switch preferredExternalMapApp {
        case .apple: preferredApp = .apple
        case .kakao: preferredApp = .kakao
        case .naver: preferredApp = .naver
        }
        if let url = ExternalMapOpener.resolvedURL(for: place, preferredApp: preferredApp) {
            openURL(url)
        }
    }
}

private struct VisitRecordListRow: View {
    private static let thumbnailSize: CGFloat = 48
    private static let spacing: CGFloat = 12

    let record: VisitRecord
    let participantNames: [String]

    var body: some View {
        HStack(alignment: .center, spacing: Self.spacing) {
            // Every row gets a tile, so titles and separators line up whether or not there is a photo.
            if let photoURL = record.photoURL {
                CachedThumbnail(url: URL(string: photoURL), size: Self.thumbnailSize, cornerRadius: 10)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                    .overlay {
                        Image(systemName: "calendar")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(Self.dateFormatter.string(from: record.visitedAt))
                    .font(.headline)

                if !participantNames.isEmpty {
                    Text(participantNames.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let average = record.averageRating {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                    Text(String(format: "%.1f", average))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
            dimensions[.leading] + Self.thumbnailSize + Self.spacing
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy.MM.dd (E)"
        return formatter
    }()
}
