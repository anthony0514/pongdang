import SwiftUI
import PhotosUI

struct VisitRecordFormView: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var visitRecordService = VisitRecordService()
    @Environment(\.dismiss) private var dismiss

    let place: Place

    @State private var visitedAt = Date()
    @State private var rating = 5
    @State private var commentText = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var photoPreview: UIImage?
    @State private var localErrorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("방문 날짜", selection: $visitedAt, displayedComponents: .date)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("별점")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        StarRatingPicker(rating: $rating)

                        Text("\(rating)점 · \(StarRatingPicker.description(for: rating))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("방문 정보")
                } footer: {
                    Text("같은 날 이미 남겨진 방문 기록이 있으면 그 기록에 댓글로 더해져요.")
                }

                Section {
                    HStack(spacing: 14) {
                        if let photoPreview {
                            VisitPhotoView(url: nil, image: photoPreview, size: 88, cornerRadius: 14)
                        }

                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label(photoPreview == nil ? "사진 선택" : "다른 사진 선택", systemImage: "photo")
                        }

                        if photoPreview != nil {
                            Spacer()
                            Button("삭제", role: .destructive) {
                                photoItem = nil
                                photoData = nil
                                photoPreview = nil
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("대표 사진")
                } footer: {
                    Text("선택하면 이 방문 기록의 대표 사진이 이 사진으로 바뀌어요.")
                }

                Section("댓글") {
                    TextEditor(text: $commentText)
                        .onChange(of: commentText) { _, newValue in
                            commentText = InputSanitizer.truncate(newValue, as: .body)
                        }
                        .frame(minHeight: 140)
                        .padding(.horizontal, -4)
                }

                if let localErrorMessage, !localErrorMessage.isEmpty {
                    Section {
                        Text(localErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .onChange(of: photoItem) { _, newItem in
                loadPhoto(from: newItem)
            }
            .navigationTitle("방문 기록 작성")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("저장") {
                        saveRecord()
                    }
                    .disabled(visitRecordService.isLoading)
                }
            }
            .overlay {
                if visitRecordService.isLoading {
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

    private func saveRecord() {
        guard let userID = authService.currentUser?.id else {
            return
        }

        let comment = InputSanitizer.sanitize(
            commentText.trimmingCharacters(in: .whitespacesAndNewlines),
            as: .body
        )

        Task {
            do {
                localErrorMessage = nil
                try await visitRecordService.recordVisit(
                    place: place,
                    visitedAt: visitedAt,
                    rating: rating,
                    body: comment,
                    photoData: photoData,
                    requestedBy: userID
                )
                LocalNotificationManager.schedule(
                    title: "방문 기록이 저장되었어요",
                    body: comment.isEmpty ? place.name : "\(place.name) · \(comment)"
                )
                dismiss()
            } catch {
                localErrorMessage = visitRecordService.errorMessage ?? error.localizedDescription
            }
        }
    }

    private func loadPhoto(from item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard
                let data = try? await item.loadTransferable(type: Data.self),
                let compressed = ImageCompressor.jpegData(from: data)
            else {
                localErrorMessage = "사진을 불러오지 못했어요."
                return
            }
            photoData = compressed
            photoPreview = UIImage(data: compressed)
        }
    }
}

struct StarRatingPicker: View {
    @Binding var rating: Int
    var size: CGFloat = 28

    var body: some View {
        HStack(spacing: size * 0.36) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    rating = value
                } label: {
                    Image(systemName: value <= rating ? "star.fill" : "star")
                        .font(.system(size: size))
                        .foregroundStyle(value <= rating ? Color.yellow : Color(.systemGray4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(value)점")
                .accessibilityAddTraits(value == rating ? .isSelected : [])
            }
        }
    }

    static func description(for rating: Int) -> String {
        switch rating {
        case 1: return "아쉬움"
        case 2: return "무난함"
        case 3: return "괜찮음"
        case 4: return "좋음"
        default: return "최고"
        }
    }
}

struct StarRatingView: View {
    let rating: Int
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { value in
                Image(systemName: value <= rating ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(value <= rating ? Color.yellow : Color(.systemGray4))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rating)점")
    }
}
