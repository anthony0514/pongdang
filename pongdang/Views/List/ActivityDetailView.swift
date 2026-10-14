import FirebaseFirestore
import MapKit
import PhotosUI
import SwiftUI

struct ActivityDetailView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var spaceService: SpaceService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var activityService = ActivityService()

    @State private var activity: ActivityRecord
    @State private var comments: [VisitComment] = []
    @State private var namesByUserID: [String: String] = [:]
    @State private var activityListener: ListenerRegistration?
    @State private var commentListener: ListenerRegistration?

    @State private var commentText = ""
    @State private var editingComment: VisitComment?
    @State private var commentToDelete: VisitComment?
    @State private var photoItem: PhotosPickerItem?
    @State private var showingPhotoPicker = false
    @State private var showingRemovePhotoAlert = false
    @State private var showingDeleteAlert = false
    @State private var showingFullMap = false
    @State private var showingTitleEditor = false
    @State private var draftTitle = ""
    @State private var errorMessage: String?
    @FocusState private var isCommentFieldFocused: Bool

    init(activity: ActivityRecord) {
        _activity = State(initialValue: activity)
    }

    private var currentUserID: String? {
        authService.currentUser?.id
    }

    private var canEditDetails: Bool {
        currentUserID != nil && !authService.isGuestUser
    }

    private var canDelete: Bool {
        currentUserID == activity.createdBy || currentUserID == spaceService.activeSpace?.createdBy
    }

    private var trimmedCommentText: String {
        commentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            MainPhotoSection(
                photoURL: activity.photoURL,
                canEdit: canEditDetails,
                onPick: { showingPhotoPicker = true },
                onRemove: { showingRemovePhotoAlert = true }
            )

            Section {
                summaryRow
                    .listRowInsets(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 16))
                    // Run the separator from the thumbnail's edge, not from the text.
                    .alignmentGuide(.listRowSeparatorLeading) { dimensions in dimensions[.leading] }

            }

            Section(comments.isEmpty ? "댓글" : "댓글 \(comments.count)") {
                if comments.isEmpty {
                    Text("아직 댓글이 없어요. 첫 댓글을 남겨보세요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(comments) { comment in
                        CommentRow(
                            comment: comment,
                            authorName: displayName(for: comment.createdBy),
                            isMine: comment.createdBy == currentUserID,
                            onEdit: { editingComment = comment },
                            onDelete: { commentToDelete = comment }
                        )
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .listSectionSpacing(.compact)
        .contentMargins(.top, 4, for: .scrollContent)
        .navigationTitle(activity.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEditDetails || canDelete {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if canEditDetails {
                            Button {
                                draftTitle = activity.customTitle ?? ""
                                showingTitleEditor = true
                            } label: {
                                Label("제목 수정", systemImage: "pencil")
                            }
                        }

                        if canDelete {
                            Button(role: .destructive) {
                                showingDeleteAlert = true
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("제목 수정", isPresented: $showingTitleEditor) {
            TextField(activity.activityType.displayName, text: $draftTitle)
            Button("저장") {
                let title = InputSanitizer.sanitize(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines), as: .title)
                run { try await activityService.setTitle(title, for: activity, requestedBy: currentUserID ?? "") }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("비워두면 \(activity.activityType.displayName)(으)로 표시돼요.")
        }
        .safeAreaInset(edge: .bottom) {
            CommentInputBar(
                text: $commentText,
                isFocused: $isCommentFieldFocused,
                canSubmit: !trimmedCommentText.isEmpty && !activityService.isLoading,
                onSubmit: submitComment
            )
        }
        .sheet(item: $editingComment) { comment in
            CommentEditorSheet(editing: comment, showsRating: false) { body, _ in
                guard let userID = currentUserID else { return }
                try await activityService.updateComment(comment, body: body, requestedBy: userID)
            }
        }
        .sheet(isPresented: $showingFullMap) {
            NavigationStack {
                ActivityRouteMap(coordinates: activity.routeCoordinates, isInteractive: true)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(activity.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("닫기") { showingFullMap = false }
                        }
                    }
            }
        }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, newItem in
            uploadPhoto(from: newItem)
        }
        .alert("대표 사진을 삭제할까요?", isPresented: $showingRemovePhotoAlert) {
            Button("삭제", role: .destructive) {
                run { try await activityService.removePhoto(from: activity, requestedBy: currentUserID ?? "") }
            }
            Button("취소", role: .cancel) {}
        }
        .alert("댓글을 삭제할까요?", isPresented: deleteCommentAlertBinding, presenting: commentToDelete) { comment in
            Button("삭제", role: .destructive) {
                run {
                    try await activityService.deleteComment(comment, requestedBy: currentUserID ?? "")
                    commentToDelete = nil
                }
            }
            Button("취소", role: .cancel) {
                commentToDelete = nil
            }
        }
        .alert("이 운동 기록을 삭제할까요?", isPresented: $showingDeleteAlert) {
            Button("삭제", role: .destructive) {
                run { try await activityService.deleteActivity(activity) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("댓글과 사진도 함께 삭제돼요. 건강 앱의 원본 기록은 그대로 남아요.")
        }
        .overlay {
            if activityService.isLoading {
                ProgressView()
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .task(id: activity.id) {
            startListening()
        }
        .task(id: ([activity.createdBy] + comments.map(\.createdBy)).joined(separator: "|")) {
            let loaded = await UserNameLoader.loadNames(
                for: [activity.createdBy] + comments.map(\.createdBy),
                excluding: namesWithCurrentUser
            )
            namesByUserID.merge(loaded) { current, _ in current }
        }
        .onDisappear {
            activityListener?.remove()
            activityListener = nil
            commentListener?.remove()
            commentListener = nil
        }
    }

    /// Route thumbnail on the left; distance leads, the rest stays quiet. Tap the map to expand it.
    private var summaryRow: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                showingFullMap = true
            } label: {
                RouteThumbnail(coordinates: activity.routeCoordinates)
                    .frame(width: 84, height: 84)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.green)
                            .frame(width: 18, height: 18)
                            .background(.background, in: Circle())
                            .padding(5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("경로 크게 보기")

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ActivityFormat.distance(activity.distanceMeters))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()

                    Text(secondaryStatsText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(timeRangeText)
                    if let sharerName = namesWithCurrentUser[activity.createdBy] {
                        Text("\(sharerName) 님이 공유")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var secondaryStatsText: String {
        var parts = [ActivityFormat.duration(activity.duration)]
        if let elevationGain = activity.elevationGainMeters, elevationGain >= 1 {
            parts.append("↑\(Int(elevationGain.rounded()))m")
        }
        return parts.joined(separator: " · ")
    }

    private var timeRangeText: String {
        "\(Self.dateFormatter.string(from: activity.startedAt)) ~ \(Self.timeFormatter.string(from: activity.endedAt))"
    }

    private var namesWithCurrentUser: [String: String] {
        var names = namesByUserID
        if let user = authService.currentUser {
            names[user.id] = user.name
        }
        return names
    }

    private func displayName(for userID: String) -> String {
        namesWithCurrentUser[userID] ?? " "
    }

    private var deleteCommentAlertBinding: Binding<Bool> {
        Binding(
            get: { commentToDelete != nil },
            set: { if !$0 { commentToDelete = nil } }
        )
    }

    private func startListening() {
        activityListener?.remove()
        activityListener = activityService.listenForActivity(activity) { updated in
            if let updated {
                activity = updated
            } else {
                dismiss()
            }
        }

        commentListener?.remove()
        commentListener = activityService.listenForComments(of: activity) { updated in
            comments = updated
        }
    }

    private func submitComment() {
        guard let userID = currentUserID, !trimmedCommentText.isEmpty else { return }
        let body = InputSanitizer.sanitize(trimmedCommentText, as: .body)
        run {
            try await activityService.addComment(body, to: activity, requestedBy: userID)
            commentText = ""
            isCommentFieldFocused = false
        }
    }

    private func uploadPhoto(from item: PhotosPickerItem?) {
        guard let item, let userID = currentUserID else { return }
        run {
            defer { photoItem = nil }
            guard
                let data = try await item.loadTransferable(type: Data.self),
                let compressed = ImageCompressor.jpegData(from: data)
            else {
                errorMessage = "사진을 불러오지 못했어요."
                return
            }
            try await activityService.setPhoto(compressed, for: activity, requestedBy: userID)
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                errorMessage = nil
                try await action()
            } catch {
                errorMessage = activityService.errorMessage ?? error.localizedDescription
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 (E) a h:mm"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "a h:mm"
        return formatter
    }()
}

private struct ActivityRouteMap: View {
    let coordinates: [CLLocationCoordinate2D]
    let isInteractive: Bool

    var body: some View {
        Map(
            initialPosition: .rect(Self.boundingRect(for: coordinates)),
            interactionModes: isInteractive ? .all : []
        ) {
            MapPolyline(coordinates: coordinates)
                .stroke(Color.green, style: StrokeStyle(lineWidth: isInteractive ? 5 : 3, lineCap: .round, lineJoin: .round))

            if isInteractive {
                if let start = coordinates.first {
                    Annotation("출발", coordinate: start) {
                        Circle().fill(.green).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }

                if let end = coordinates.last, coordinates.count > 1 {
                    Annotation("도착", coordinate: end) {
                        Circle().fill(.red).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }

    private static func boundingRect(for coordinates: [CLLocationCoordinate2D]) -> MKMapRect {
        let points = coordinates.map(MKMapPoint.init)
        guard let first = points.first else { return .world }

        var rect = MKMapRect(origin: first, size: MKMapSize(width: 0, height: 0))
        for point in points.dropFirst() {
            rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
        }

        let padding = max(rect.size.width, rect.size.height) * 0.15 + 100
        return rect.insetBy(dx: -padding, dy: -padding)
    }
}
