import SwiftUI
import PhotosUI
import FirebaseFirestore

struct VisitDetailView: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var visitRecordService = VisitRecordService()
    @Environment(\.dismiss) private var dismiss

    var onShowPlace: (() -> Void)?

    @State private var visit: VisitRecord
    @State private var comments: [VisitComment] = []
    @State private var namesByUserID: [String: String] = [:]
    @State private var visitListener: ListenerRegistration?
    @State private var commentListener: ListenerRegistration?
    @State private var hasLoadedVisit = false

    @State private var showingComposer = false
    @State private var editingComment: VisitComment?
    @State private var commentToDelete: VisitComment?
    @State private var localErrorMessage: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var showingPhotoPicker = false
    @State private var showingRemovePhotoAlert = false
    @State private var showingShareSheet = false

    init(visit: VisitRecord, onShowPlace: (() -> Void)? = nil) {
        _visit = State(initialValue: visit)
        self.onShowPlace = onShowPlace
    }

    private var currentUserID: String? {
        authService.currentUser?.id
    }

    /// Any space member can add, replace, or remove the photo.
    private var canEditPhoto: Bool {
        currentUserID != nil && !authService.isGuestUser
    }

    private var allComments: [VisitComment] {
        (visit.legacyComments + comments).sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        List {
            MainPhotoSection(
                photoURL: visit.photoURL,
                canEdit: canEditPhoto,
                onPick: { showingPhotoPicker = true },
                onRemove: { showingRemovePhotoAlert = true }
            )

            Section {
                if let onShowPlace {
                    Button {
                        onShowPlace()
                    } label: {
                        HStack {
                            titleCard
                            Spacer(minLength: 8)
                            Image(systemName: "map")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("지도에서 장소를 보여줘요")
                } else {
                    titleCard
                }

            }

            Section(allComments.isEmpty ? "댓글" : "댓글 \(allComments.count)") {
                if allComments.isEmpty {
                    Text("아직 댓글이 없어요. 첫 댓글을 남겨보세요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(allComments) { comment in
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

            if let localErrorMessage, !localErrorMessage.isEmpty {
                Section {
                    Text(localErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .listSectionSpacing(.compact)
        .contentMargins(.top, 4, for: .scrollContent)
        .navigationTitle("방문 기록")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("공유")
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            VisitShareSheet(
                visit: visit,
                comments: allComments
                    .filter { !$0.body.isEmpty }
                    .map { VisitShareSheet.SharedComment(authorName: displayName(for: $0.createdBy), body: $0.body) }
            )
        }
        // Keep the last comment clear of the floating button.
        .contentMargins(.bottom, 84, for: .scrollContent)
        .overlay(alignment: .bottomTrailing) {
            if !authService.isGuestUser {
                FloatingWriteButton(accessibilityLabel: "댓글 남기기") {
                    showingComposer = true
                }
            }
        }
        .sheet(isPresented: $showingComposer) {
            CommentEditorSheet(showsRating: true) { body, rating in
                guard let userID = currentUserID else { return }
                try await visitRecordService.addComment(body, rating: rating, to: visit, requestedBy: userID)
            }
        }
        .sheet(item: $editingComment) { comment in
            CommentEditorSheet(editing: comment, showsRating: true) { body, rating in
                try await updateComment(comment, body: body, rating: rating)
            }
        }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, newItem in
            uploadPhoto(from: newItem)
        }
        .alert("대표 사진을 삭제할까요?", isPresented: $showingRemovePhotoAlert) {
            Button("삭제", role: .destructive) {
                removePhoto()
            }
            Button("취소", role: .cancel) {}
        }
        .overlay {
            if visitRecordService.isLoading {
                ProgressView()
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .alert("댓글을 삭제할까요?", isPresented: deleteCommentAlertBinding, presenting: commentToDelete) { comment in
            Button("삭제", role: .destructive) {
                deleteComment(comment)
            }
            Button("취소", role: .cancel) {
                commentToDelete = nil
            }
        } message: { _ in
            Text("댓글과 함께 남긴 별점도 삭제돼요.")
        }
        .task(id: visit.id) {
            startListening()
        }
        .task(id: allComments.map(\.createdBy).joined(separator: "|")) {
            let loaded = await UserNameLoader.loadNames(
                for: allComments.map(\.createdBy),
                excluding: namesWithCurrentUser
            )
            namesByUserID.merge(loaded) { current, _ in current }
        }
        .onDisappear {
            visitListener?.remove()
            visitListener = nil
            commentListener?.remove()
            commentListener = nil
        }
    }

    private var titleCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(visit.placeName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                Text(Self.dateFormatter.string(from: visit.visitedAt))

                if let average = visit.averageRating {
                    Label(String(format: "%.1f", average), systemImage: "star.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.orange)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
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
        visitListener?.remove()
        visitListener = visitRecordService.listenForPlaceRecords(spaceID: visit.spaceID, placeID: visit.placeID) { records in
            if let updated = records.first(where: { $0.id == visit.id }) {
                visit = updated
                hasLoadedVisit = true
            } else if hasLoadedVisit {
                // The last comment was deleted, so the visit no longer exists.
                dismiss()
            }
        }

        commentListener?.remove()
        commentListener = visitRecordService.listenForComments(of: visit) { updated in
            comments = updated
        }
    }

    private func updateComment(_ comment: VisitComment, body: String, rating: Int) async throws {
        guard let userID = currentUserID else { return }
        try await visitRecordService.updateComment(comment, body: body, rating: rating, requestedBy: userID)
    }

    private func deleteComment(_ comment: VisitComment) {
        guard let userID = currentUserID else { return }
        Task {
            do {
                localErrorMessage = nil
                try await visitRecordService.deleteComment(comment, placeID: visit.placeID, requestedBy: userID)
                commentToDelete = nil
            } catch {
                localErrorMessage = visitRecordService.errorMessage ?? error.localizedDescription
            }
        }
    }

    private func uploadPhoto(from item: PhotosPickerItem?) {
        guard let item, let userID = currentUserID else { return }
        Task {
            defer { photoItem = nil }
            do {
                localErrorMessage = nil
                guard
                    let data = try await item.loadTransferable(type: Data.self),
                    let compressed = ImageCompressor.jpegData(from: data)
                else {
                    localErrorMessage = "사진을 불러오지 못했어요."
                    return
                }
                try await visitRecordService.setPhoto(compressed, for: visit, requestedBy: userID)
            } catch {
                localErrorMessage = visitRecordService.errorMessage ?? error.localizedDescription
            }
        }
    }

    private func removePhoto() {
        guard let userID = currentUserID else { return }
        Task {
            do {
                localErrorMessage = nil
                try await visitRecordService.removePhoto(from: visit, requestedBy: userID)
            } catch {
                localErrorMessage = visitRecordService.errorMessage ?? error.localizedDescription
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy.MM.dd (E)"
        return formatter
    }()
}
