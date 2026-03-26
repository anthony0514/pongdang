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

    private var isEditing: Bool {
        existingRecord != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("방문 정보") {
                    DatePicker("방문 날짜", selection: $visitedAt, displayedComponents: .date)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("별점")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        StarRatingPicker(rating: $rating)

                        Text("\(rating)점 · \(ratingDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("기록") {
                    TextField("한 줄 제목", text: $title)
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 140)
                }
            }
            .navigationTitle(isEditing ? "방문 기록 수정" : "방문 기록 작성")
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
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
            rating: rating,
            photoURLs: existingRecord?.photoURLs ?? [],
            visitedAt: visitedAt,
            createdBy: existingRecord?.createdBy ?? userID,
            createdAt: existingRecord?.createdAt ?? Date()
        )

        Task {
            do {
                if isEditing {
                    try await visitRecordService.updateVisitRecord(record)
                } else {
                    try await visitRecordService.addVisitRecord(record)
                }
                dismiss()
            } catch {
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
