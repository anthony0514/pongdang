import SwiftUI
import FirebaseFirestore

struct HistoryCalendarView: View {
    struct GroupedVisitRecord: Identifiable {
        let placeID: String
        let placeName: String
        let records: [VisitRecord]

        var id: String { placeID }
        var count: Int { records.count }
        var latestVisitedAt: Date { records.map(\.visitedAt).max() ?? .distantPast }
        var latestRecord: VisitRecord? { records.max(by: { $0.visitedAt < $1.visitedAt }) }
    }

    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var navigationState: AppNavigationState

    @StateObject private var viewModel = MapViewModel()
    @StateObject private var visitRecordService = VisitRecordService()

    @State private var visitRecords: [VisitRecord] = []
    @State private var selectedDate = Date()
    @State private var displayedMonth = Date()
    @State private var visitRecordListener: ListenerRegistration?
    @State private var authorNamesByUserID: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if spaceService.activeSpace == nil {
                    ContentUnavailableView(
                        "스페이스가 없습니다",
                        systemImage: "calendar",
                        description: Text("먼저 스페이스를 만들거나 참여해 주세요.")
                    )
                } else {
                    List {
                        Section {
                            VisitCalendarMonthView(
                                displayedMonth: $displayedMonth,
                                selectedDate: $selectedDate,
                                highlightedDates: highlightedDates,
                                plannedDates: plannedDates
                            )
                            .frame(height: VisitCalendarMonthView.height(for: displayedMonth))
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        }

                        Section(selectedDateTitle) {
                            if groupedRecordsForSelectedDate.isEmpty {
                                Text("선택한 날짜에는 방문 기록이 없습니다.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(groupedRecordsForSelectedDate) { group in
                                    if let place = placeByID[group.placeID] {
                                        Button {
                                            navigationState.showPlaceOnMap(
                                                placeID: place.id,
                                                presentDetail: true,
                                                compactDetailSheet: true
                                            )
                                        } label: {
                                            GroupedVisitRecordRow(group: group)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        GroupedVisitRecordRow(group: group)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("캘린더")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                displayedMonth = Self.monthStart(for: selectedDate)
                if let space = spaceService.activeSpace {
                    viewModel.fetchPlaces(for: space.id)
                    listenForVisitRecords(spaceID: space.id)
                }
            }
            .onChange(of: spaceService.activeSpace) { _, space in
                if let space {
                    viewModel.fetchPlaces(for: space.id)
                    listenForVisitRecords(spaceID: space.id)
                } else {
                    visitRecords = []
                    visitRecordListener?.remove()
                    visitRecordListener = nil
                }
            }
            .onDisappear {
                visitRecordListener?.remove()
                visitRecordListener = nil
            }
            .onChange(of: selectedDate) { _, newDate in
                displayedMonth = Self.monthStart(for: newDate)
            }
            .task(id: visitRecords.map(\.createdBy).joined(separator: "|")) {
                await loadAuthorNamesIfNeeded()
            }
        }
    }

    private var placeByID: [String: Place] {
        Dictionary(uniqueKeysWithValues: viewModel.places.map { ($0.id, $0) })
    }

    private var recordsForSelectedDate: [VisitRecord] {
        visitRecords.filter { Calendar.current.isDate($0.visitedAt, inSameDayAs: selectedDate) }
    }

    private var groupedRecordsForSelectedDate: [GroupedVisitRecord] {
        let grouped = Dictionary(grouping: recordsForSelectedDate) { record in
            record.placeID
        }

        return grouped.compactMap { placeID, records in
            let sortedRecords = records.sorted { lhs, rhs in
                if lhs.visitedAt != rhs.visitedAt {
                    return lhs.visitedAt > rhs.visitedAt
                }
                return lhs.createdAt > rhs.createdAt
            }

            guard let first = sortedRecords.first else { return nil }

            return GroupedVisitRecord(
                placeID: placeID,
                placeName: first.placeName,
                records: sortedRecords
            )
        }
        .sorted { lhs, rhs in
            lhs.latestVisitedAt > rhs.latestVisitedAt
        }
    }

    private var selectedDateTitle: String {
        Self.dateFormatter.string(from: selectedDate)
    }

    private var highlightedDates: Set<Date> {
        let today = Calendar.current.startOfDay(for: Date())
        return Set(
            visitRecords
                .map { Calendar.current.startOfDay(for: $0.visitedAt) }
                .filter { $0 <= today }
        )
    }

    private var plannedDates: Set<Date> {
        let today = Calendar.current.startOfDay(for: Date())
        return Set(
            visitRecords
                .map { Calendar.current.startOfDay(for: $0.visitedAt) }
                .filter { $0 > today }
        )
    }

    private func listenForVisitRecords(spaceID: String) {
        visitRecordListener?.remove()
        visitRecordListener = visitRecordService.listenForSpaceRecords(spaceID: spaceID) { records in
            visitRecords = records
        }
    }

    private func authorName(for group: GroupedVisitRecord) -> String? {
        guard let latestRecord = group.latestRecord else { return nil }

        if latestRecord.createdBy == authService.currentUser?.id {
            return authService.currentUser?.name
        }

        return authorNamesByUserID[latestRecord.createdBy]
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
                    authorNamesByUserID[userID] = userID == "guest-user" ? "익명" : "알 수 없음"
                }
            } catch {
                authorNamesByUserID[userID] = userID == "guest-user" ? "익명" : "알 수 없음"
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()

    private static func monthStart(for date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }
}

private struct GroupedVisitRecordRow: View {
    let group: HistoryCalendarView.GroupedVisitRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 6) {
                Text(group.placeName)
                    .font(.headline)
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    Text(Self.dateFormatter.string(from: group.latestVisitedAt))
                    Text("\(group.count)개 기록")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()
}

private struct VisitCalendarMonthView: View {
    @Binding var displayedMonth: Date
    @Binding var selectedDate: Date

    let highlightedDates: Set<Date>
    let plannedDates: Set<Date>

    private let calendar = Calendar.current
    private let weekdaySymbols = Calendar.current.shortWeekdaySymbols
    private static let headerHeight: CGFloat = 32
    private static let topSectionSpacing: CGFloat = 12
    private static let weekdayRowHeight: CGFloat = 18
    private static let weekRowHeight: CGFloat = 46
    private static let gridRowSpacing: CGFloat = 10
    private static let verticalPadding: CGFloat = 16

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    moveMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                Text(monthTitle)
                    .font(.headline)

                Spacer()

                Button {
                    moveMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 10) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                ForEach(monthDays) { day in
                    if let date = day.date {
                        Button {
                            selectedDate = date
                        } label: {
                            VStack(spacing: 4) {
                                Text("\(calendar.component(.day, from: date))")
                                    .font(.subheadline.weight(isSelected(date) ? .bold : .regular))
                                    .foregroundStyle(dayTextColor(for: date))
                                    .frame(width: 36, height: 36)
                                    .background(
                                        dayBackground(for: date)
                                    )
                                    .overlay(
                                        dayBorder(for: date)
                                    )

                                Circle()
                                    .fill(markerColor(on: date))
                                    .frame(width: 6, height: 6)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear
                            .frame(height: 46)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var monthTitle: String {
        Self.monthFormatter.string(from: displayedMonth)
    }

    private var monthDays: [CalendarDay] {
        guard let dayRange = calendar.range(of: .day, in: .month, for: displayedMonth),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) else {
            return []
        }

        let leadingBlankCount = (calendar.component(.weekday, from: firstOfMonth) - calendar.firstWeekday + 7) % 7
        var days = (0..<leadingBlankCount).map { index in
            CalendarDay(id: "blank-\(index)", date: nil)
        }

        days.append(contentsOf: dayRange.compactMap { day -> CalendarDay? in
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth) else { return nil }
            return CalendarDay(id: Self.dayIDFormatter.string(from: date), date: date)
        })

        return days
    }

    private var weekRowCount: Int {
        Int(ceil(Double(monthDays.count) / 7.0))
    }

    private func moveMonth(by value: Int) {
        guard let nextMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) else { return }
        displayedMonth = nextMonth
    }

    private func hasRecord(on date: Date) -> Bool {
        highlightedDates.contains(calendar.startOfDay(for: date))
    }

    private func markerColor(on date: Date) -> Color {
        let day = calendar.startOfDay(for: date)

        if plannedDates.contains(day) {
            return .red
        }

        if highlightedDates.contains(day) {
            return Color.accentColor
        }

        return .clear
    }

    @ViewBuilder
    private func dayBackground(for date: Date) -> some View {
        let day = calendar.startOfDay(for: date)

        if isSelected(date) {
            Circle().fill(Color.accentColor)
        } else if highlightedDates.contains(day) || plannedDates.contains(day) {
            Circle().fill(Color(.systemGray5))
        } else {
            Circle().fill(Color.clear)
        }
    }

    private func dayTextColor(for date: Date) -> Color {
        isSelected(date) ? .white : .primary
    }

    @ViewBuilder
    private func dayBorder(for date: Date) -> some View {
        if isToday(date) && !isSelected(date) {
            Circle()
                .stroke(DesignSystem.Colors.primary, lineWidth: 1.5)
        } else {
            Circle()
                .stroke(Color.clear, lineWidth: 0)
        }
    }

    private func isToday(_ date: Date) -> Bool {
        calendar.isDateInToday(date)
    }

    private func isSelected(_ date: Date) -> Bool {
        calendar.isDate(date, inSameDayAs: selectedDate)
    }

    private struct CalendarDay: Identifiable {
        let id: String
        let date: Date?
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy년 M월"
        return formatter
    }()

    private static let dayIDFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func height(for month: Date) -> CGFloat {
        let calendar = Calendar.current
        guard let dayRange = calendar.range(of: .day, in: .month, for: month),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) else {
            return 330
        }

        let leadingBlankCount = (calendar.component(.weekday, from: firstOfMonth) - calendar.firstWeekday + 7) % 7
        let dayCellCount = leadingBlankCount + dayRange.count
        let weekRowCount = Int(ceil(Double(dayCellCount) / 7.0))

        return headerHeight
            + topSectionSpacing
            + weekdayRowHeight
            + gridRowSpacing
            + (CGFloat(weekRowCount) * weekRowHeight)
            + (CGFloat(max(weekRowCount - 1, 0)) * gridRowSpacing)
            + verticalPadding
    }
}
