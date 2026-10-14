import SwiftUI

// Shared pieces for the visit and activity detail screens.

struct CommentRow: View {
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

                if isMine {
                    menu
                }
            }

            if !comment.body.isEmpty {
                Text(comment.body)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Time sits under the comment, away from the menu button.
            HStack(spacing: 4) {
                Text(Self.relativeFormatter.localizedString(for: comment.createdAt, relativeTo: Date()))

                if comment.updatedAt != nil {
                    Text("· 수정됨")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var menu: some View {
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .short
        return formatter
    }()
}

/// Bottom bar for writing a comment. Pass `rating` to show a star picker.
struct CommentInputBar: View {
    @Binding var text: String
    var rating: Binding<Int>?
    var isFocused: FocusState<Bool>.Binding
    let canSubmit: Bool
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let rating {
                StarRatingPicker(rating: rating, size: 20)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("댓글 남기기", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused(isFocused)
                    .onChange(of: text) { _, newValue in
                        text = InputSanitizer.truncate(newValue, as: .body)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button {
                    onSubmit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                }
                .disabled(!canSubmit)
                .accessibilityLabel("댓글 등록")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Sheet for writing a new comment or editing one.
struct CommentEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let saveTitle: String
    let showsRating: Bool
    let onSave: (String, Int) async throws -> Void

    @State private var rating: Int
    @State private var text: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isTextFocused: Bool

    /// New comment.
    init(showsRating: Bool, onSave: @escaping (String, Int) async throws -> Void) {
        self.title = "댓글 남기기"
        self.saveTitle = "등록"
        self.showsRating = showsRating
        self.onSave = onSave
        _rating = State(initialValue: 5)
        _text = State(initialValue: "")
    }

    /// Edit an existing comment.
    init(editing comment: VisitComment, showsRating: Bool, onSave: @escaping (String, Int) async throws -> Void) {
        self.title = "댓글 편집"
        self.saveTitle = "저장"
        self.showsRating = showsRating
        self.onSave = onSave
        _rating = State(initialValue: max(comment.rating, 1))
        _text = State(initialValue: comment.body)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                if showsRating {
                    Section("별점") {
                        StarRatingPicker(rating: $rating)
                    }
                }

                Section("댓글") {
                    TextEditor(text: $text)
                        .focused($isTextFocused)
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saveTitle) { save() }
                        // Without a rating, an empty comment would carry nothing.
                        .disabled(isSaving || (!showsRating && trimmedText.isEmpty))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            // Ratings come first when shown; otherwise jump straight into typing.
            if !showsRating { isTextFocused = true }
        }
    }

    private func save() {
        let body = InputSanitizer.sanitize(trimmedText, as: .body)
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

/// Round floating button in the bottom-right corner, matching the place detail's write button.
struct FloatingWriteButton: View {
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "pencil")
                .font(.system(size: 24, weight: .bold))
                .frame(width: 58, height: 58)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .padding(.trailing, 20)
        .padding(.bottom, 12)
    }
}

/// Main photo as its own list section: a centered rounded square with no cell background.
/// Without a photo, editors see an empty placeholder they can tap to upload.
struct MainPhotoSection: View {
    let photoURL: String?
    let canEdit: Bool
    let onPick: () -> Void
    let onRemove: () -> Void

    private let side: CGFloat = 220
    private let cornerRadius: CGFloat = 24

    var body: some View {
        if photoURL != nil || canEdit {
            Section {
                HStack {
                    Spacer(minLength: 0)
                    content
                        .frame(width: side, height: side)
                    Spacer(minLength: 0)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let photoURL {
            if canEdit {
                // Tapping the photo itself opens change/remove.
                Menu {
                    Button {
                        onPick()
                    } label: {
                        Label("사진 변경", systemImage: "photo")
                    }

                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label("사진 삭제", systemImage: "trash")
                    }
                } label: {
                    photo(photoURL)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("대표 사진 옵션")
            } else {
                photo(photoURL)
            }
        } else {
            Button {
                onPick()
            } label: {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color(.tertiaryLabel), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    }
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 30, weight: .regular))
                            Text("사진 추가")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("대표 사진 추가")
        }
    }

    private func photo(_ photoURL: String) -> some View {
        VisitPhotoView(url: URL(string: photoURL), cornerRadius: cornerRadius)
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }
}
