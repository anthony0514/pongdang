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

    @State private var commentText = ""
    @State private var newRating = 5
    @State private var editingComment: VisitComment?
    @State private var commentToDelete: VisitComment?
    @State private var localErrorMessage: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var showingPhotoPicker = false
    @State private var showingRemovePhotoAlert = false
    @FocusState private var isCommentFieldFocused: Bool

    init(visit: VisitRecord, onShowPlace: (() -> Void)? = nil) {
        _visit = State(initialValue: visit)
        self.onShowPlace = onShowPlace
    }

    private var currentUserID: String? {
        authService.currentUser?.id
    }

    /// Only people who commented on this visit can change its photo.
    private var canEditPhoto: Bool {
        guard let currentUserID else { return false }
        return visit.ratings[currentUserID]?.isEmpty == false
    }

    private var allComments: [VisitComment] {
        (visit.legacyComments + comments).sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        List {
            Section {
                photoSection

                VStack(alignment: .leading, spacing: 6) {
                    Text(visit.placeName)
                        .font(.title3.weight(.semibold))

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

                if let onShowPlace {
                    Button {
                        onShowPlace()
                    } label: {
                        Label("지도에서 보기", systemImage: "map")
                    }
                }
            }

            Section("댓글") {
                if allComments.isEmpty {
                    Text("아직 댓글이 없어요. 첫 댓글을 남겨보세요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(allComments) { comment in
                        VisitCommentRow(
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
        .navigationTitle("방문 기록")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            commentInputBar
        }
        .sheet(item: $editingComment) { comment in
            CommentEditSheet(comment: comment) { body, rating in
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

    @ViewBuilder
    private var photoSection: some View {
        if let photoURL = visit.photoURL {
            VisitPhotoView(url: URL(string: photoURL))
                .overlay(alignment: .topTrailing) {
                    if canEditPhoto {
                        Menu {
                            Button {
                                showingPhotoPicker = true
                            } label: {
                                Label("사진 변경", systemImage: "photo")
                            }

                            Button(role: .destructive) {
                                showingRemovePhotoAlert = true
                            } label: {
                                Label("사진 삭제", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                        .padding(10)
                        .accessibilityLabel("사진 옵션")
                    }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
        } else if canEditPhoto {
            Button {
                showingPhotoPicker = true
            } label: {
                Label("대표 사진 추가", systemImage: "photo.badge.plus")
            }
        }
    }

    private var commentInputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            StarRatingPicker(rating: $newRating, size: 20)

            HStack(alignment: .bottom, spacing: 10) {
                TextField("댓글 남기기", text: $commentText, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($isCommentFieldFocused)
                    .onChange(of: commentText) { _, newValue in
                        commentText = InputSanitizer.truncate(newValue, as: .body)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button {
                    submitComment()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                }
                .disabled(visitRecordService.isLoading)
                .accessibilityLabel("댓글 등록")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
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

    private func submitComment() {
        guard let userID = currentUserID else { return }
        let body = InputSanitizer.sanitize(
            commentText.trimmingCharacters(in: .whitespacesAndNewlines),
            as: .body
        )
        let rating = newRating

        Task {
            do {
                localErrorMessage = nil
                try await visitRecordService.addComment(body, rating: rating, to: visit, requestedBy: userID)
                commentText = ""
                newRating = 5
                isCommentFieldFocused = false
            } catch {
                localErrorMessage = visitRecordService.errorMessage ?? error.localizedDescription
            }
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

private struct VisitCommentRow: View {
    let comment: VisitComment
    let authorName: String
    let isMine: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(authorName)
                    .font(.subheadline.weight(.semibold))

                if comment.rating > 0 {
                    StarRatingView(rating: comment.rating, size: 11)
                }

                Spacer(minLength: 4)

                Text(Self.relativeFormatter.localizedString(for: comment.createdAt, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if comment.updatedAt != nil {
                    Text("수정됨")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isMine {
                    Menu {
                        if !comment.isLegacy {
                            Button {
                                onEdit()
                            } label: {
                                Label("편집", systemImage: "pencil")
                            }
                        }

                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label("삭제", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("댓글 옵션")
                }
            }

            if !comment.body.isEmpty {
                Text(comment.body)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct CommentEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    let comment: VisitComment
    let onSave: (String, Int) async throws -> Void

    @State private var rating: Int
    @State private var text: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(comment: VisitComment, onSave: @escaping (String, Int) async throws -> Void) {
        self.comment = comment
        self.onSave = onSave
        _rating = State(initialValue: max(comment.rating, 1))
        _text = State(initialValue: comment.body)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("별점") {
                    StarRatingPicker(rating: $rating)
                }

                Section("댓글") {
                    TextEditor(text: $text)
                        .onChange(of: text) { _, newValue in
                            text = InputSanitizer.truncate(newValue, as: .body)
                        }
                        .frame(minHeight: 140)
                        .padding(.horizontal, -4)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("댓글 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("저장") { save() }
                        .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let body = InputSanitizer.sanitize(text.trimmingCharacters(in: .whitespacesAndNewlines), as: .body)
        isSaving = true
        Task {
            do {
                try await onSave(body, rating)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
