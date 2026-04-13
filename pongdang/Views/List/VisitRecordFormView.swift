import SwiftUI

struct VisitRecordFormView: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var visitRecordService = VisitRecordService()
    @Environment(\.dismiss) private var dismiss

    let place: Place
    let existingRecord: VisitRecord?

    @State private var visitedAt = Date()
    @State private var rating = 5
    @State private var title = ""
    @State private var bodyText = ""
    @State private var localErrorMessage: String?

    private var isEditing: Bool {
        existingRecord != nil
    }

    private var canEditRecord: Bool {
        guard let existingRecord else { return true }
        return existingRecord.createdBy == authService.currentUser?.id
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("방문 정보") {
                    DatePicker("방문 날짜", selection: $visitedAt, displayedComponents: .date)
                        .disabled(!canEditRecord)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("별점")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        StarRatingPicker(rating: $rating)
                            .disabled(!canEditRecord)

                        Text("\(rating)점 · \(ratingDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("기록") {
                    TextField("한 줄 제목", text: $title)
                        .onChange(of: title) { _, newValue in
                            title = InputSanitizer.truncate(newValue, as: .title)
                        }
                        .disabled(!canEditRecord)
                    TextEditor(text: $bodyText)
                        .onChange(of: bodyText) { _, newValue in
                            bodyText = InputSanitizer.truncate(newValue, as: .body)
                        }
                        .frame(minHeight: 140)
                        .padding(.horizontal, -4)
                        .disabled(!canEditRecord)
                }

                if isEditing && !canEditRecord {
                    Section {
                        Text("다른 멤버가 작성한 기록은 수정할 수 없습니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
            .navigationTitle(navigationTitle)
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
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canEditRecord)
                }
            }
            .onAppear {
                guard let existingRecord else { return }
                visitedAt = existingRecord.visitedAt
                rating = existingRecord.rating
                title = existingRecord.title
                bodyText = existingRecord.body ?? ""
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

        let record = VisitRecord(
            id: existingRecord?.id ?? UUID().uuidString,
            placeID: place.id,
            spaceID: place.spaceID,
            placeName: place.name,
            title: InputSanitizer.sanitize(title.trimmingCharacters(in: .whitespacesAndNewlines), as: .title),
            body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : InputSanitizer.sanitize(bodyText.trimmingCharacters(in: .whitespacesAndNewlines), as: .body),
            rating: rating,
            photoURLs: existingRecord?.photoURLs ?? [],
            visitedAt: visitedAt,
            createdBy: existingRecord?.createdBy ?? userID,
            createdAt: existingRecord?.createdAt ?? Date()
        )

        Task {
            do {
                localErrorMessage = nil
                if isEditing {
                    try await visitRecordService.updateVisitRecord(record, requestedBy: userID)
                } else {
                    try await visitRecordService.addVisitRecord(record, requestedBy: userID)
                    LocalNotificationManager.schedule(
                        title: "방문 기록이 저장되었어요",
                        body: "\(place.name) · \(record.title)"
                    )
                }
                dismiss()
            } catch {
                localErrorMessage = visitRecordService.errorMessage ?? error.localizedDescription
            }
        }
    }

    private var ratingDescription: String {
        switch rating {
        case 1: return "아쉬움"
        case 2: return "무난함"
        case 3: return "괜찮음"
        case 4: return "좋음"
        default: return "최고"
        }
    }

    private var navigationTitle: String {
        if !isEditing {
            return "방문 기록 작성"
        }

        return canEditRecord ? "방문 기록 수정" : "방문 기록 보기"
    }
}

private struct StarRatingPicker: View {
    @Binding var rating: Int

    var body: some View {
        HStack(spacing: 10) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    rating = value
                } label: {
                    Image(systemName: value <= rating ? "star.fill" : "star")
                        .font(.system(size: 28))
                        .foregroundStyle(value <= rating ? Color.yellow : Color(.systemGray4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(value)점")
                .accessibilityAddTraits(value == rating ? .isSelected : [])
            }
        }
    }
}
