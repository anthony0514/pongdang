import SwiftUI

/// Picks the day a visit or walk shows up on in the calendar.
/// A late-night date that ran past midnight can go back a day with one tap.
struct CalendarDateEditorSheet: View {
    let title: String
    let message: String
    /// The record's own day (e.g. when the walk started), offered as "원래 날짜로".
    let originalDate: Date?
    let onSave: (Date) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate: Date
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let initialDate: Date

    init(
        title: String,
        message: String,
        currentDate: Date,
        originalDate: Date? = nil,
        onSave: @escaping (Date) async throws -> Void
    ) {
        self.title = title
        self.message = message
        self.originalDate = originalDate
        self.onSave = onSave
        let day = Calendar.current.startOfDay(for: currentDate)
        self.initialDate = day
        _selectedDate = State(initialValue: day)
    }

    private var hasChanges: Bool {
        !Calendar.current.isDate(selectedDate, inSameDayAs: initialDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "날짜",
                        selection: $selectedDate,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                } footer: {
                    Text(message)
                }

                Section {
                    Button {
                        shiftSelectedDate(byDays: -1)
                    } label: {
                        Label("하루 전으로", systemImage: "moon.stars")
                    }

                    if let originalDate,
                       !Calendar.current.isDate(selectedDate, inSameDayAs: originalDate) {
                        Button {
                            selectedDate = Calendar.current.startOfDay(for: originalDate)
                        } label: {
                            Label("원래 날짜로 (\(Self.dayFormatter.string(from: originalDate)))", systemImage: "arrow.uturn.backward")
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("저장") { save() }
                            .disabled(!hasChanges)
                    }
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
        .presentationDetents([.large])
    }

    private func shiftSelectedDate(byDays days: Int) {
        if let shifted = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) {
            selectedDate = shifted
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await onSave(selectedDate)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일"
        return formatter
    }()
}
