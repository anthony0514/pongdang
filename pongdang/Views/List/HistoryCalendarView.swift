import SwiftUI
import FirebaseFirestore

struct HistoryCalendarView: View {
    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var navigationState: AppNavigationState

    @StateObject private var viewModel = MapViewModel()
    @StateObject private var visitRecordService = VisitRecordService()
    @StateObject private var activityService = ActivityService()

    @State private var visitRecords: [VisitRecord] = []
    @State private var selectedDate = Date()
    @State private var displayedMonth = Date()
    @State private var visitRecordListener: ListenerRegistration?
    @State private var authorNamesByUserID: [String: String] = [:]
    @State private var selectedVisit: VisitRecord?
    @State private var activities: [ActivityRecord] = []
    @State private var activityListener: ListenerRegistration?
    @State private var selectedActivity: ActivityRecord?
    @State private var showingHealthImport = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

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
                                plannedDates: plannedDates,
                                activityDates: activityDates
                            )
                            .frame(height: VisitCalendarMonthView.height(for: displayedMonth))
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        }

                        Section(selectedDateTitle) {
                            if recordsForSelectedDate.isEmpty {
                                Text("선택한 날짜에는 방문 기록이 없습니다.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(recordsForSelectedDate) { record in
                                    Button {
                                        selectedVisit = record
                                    } label: {
                                        CalendarVisitRow(
                                            record: record,
                                            place: placeByID[record.placeID],
                                            participantNames: participantNames(for: record)
                                        )
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if !activitiesForSelectedDate.isEmpty {
                            Section("운동") {
                                ForEach(activitiesForSelectedDate) { activity in
                                    Button {
                                        selectedActivity = activity
                                    } label: {
                                        CalendarActivityRow(activity: activity)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("캘린더")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selectedVisit) { visit in
                VisitDetailView(visit: visit, onShowPlace: showPlaceAction(for: visit))
                    .environmentObject(authService)
            }
            .navigationDestination(item: $selectedActivity) { activity in
                ActivityDetailView(activity: activity)
                    .environmentObject(authService)
                    .environmentObject(spaceService)
            }
            .toolbar {
                if spaceService.activeSpace != nil && !authService.isGuestUser {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingHealthImport = true
                        } label: {
                            Image(systemName: "figure.walk.motion")
                        }
                        .accessibilityLabel("건강에서 운동 가져오기")
                    }
                }
            }
            .sheet(isPresented: $showingHealthImport) {
                if let space = spaceService.activeSpace {
                    HealthWorkoutPickerView(space: space)
                        .environmentObject(authService)
                }
            }
            .onAppear {
                displayedMonth = Self.monthStart(for: selectedDate)
                if let space = spaceService.activeSpace {
                    viewModel.fetchPlaces(for: space.id)
                    listenForVisitRecords(spaceID: space.id)
                    listenForActivities(spaceID: space.id)
                }
            }
            .onChange(of: spaceService.activeSpace) { _, space in
                if let space {
                    viewModel.fetchPlaces(for: space.id)
                    listenForVisitRecords(spaceID: space.id)
                    listenForActivities(spaceID: space.id)
                } else {
                    visitRecords = []
                    activities = []
                    visitRecordListener?.remove()
                    visitRecordListener = nil
                    activityListener?.remove()
                    activityListener = nil
                }
            }
            .onDisappear {
                visitRecordListener?.remove()
                visitRecordListener = nil
                activityListener?.remove()
                activityListener = nil
            }
            .onChange(of: selectedDate) { _, newDate in
                displayedMonth = Self.monthStart(for: newDate)
            }
            .task(id: visitRecords.flatMap(\.participantIDs).joined(separator: "|")) {
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

    private var activitiesForSelectedDate: [ActivityRecord] {
        activities.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: selectedDate) }
    }

    private var activityDates: Set<Date> {
        Set(activities.map { Calendar.current.startOfDay(for: $0.startedAt) })
    }

    private func listenForActivities(spaceID: String) {
        activityListener?.remove()
        activityListener = activityService.listenForSpaceActivities(spaceID: spaceID) { updated in
            activities = updated
        }
    }

    private func showPlaceAction(for visit: VisitRecord) -> (() -> Void)? {
        guard placeByID[visit.placeID] != nil else { return nil }
        return {
            selectedVisit = nil
            navigationState.showPlaceOnMap(
                placeID: visit.placeID,
                presentDetail: true,
                compactDetailSheet: true
            )
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

private struct CalendarVisitRow: View {
    let record: VisitRecord
    let place: Place?
    let participantNames: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    if let photoURL = record.photoURL {
                        VisitPhotoView(url: URL(string: photoURL), size: 34, cornerRadius: 8)
                    } else {
                        categoryIcon
                    }

                    Text(record.placeName)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer(minLength: 8)

                    if let average = record.averageRating {
                        Label(String(format: "%.1f", average), systemImage: "star.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                if !participantNames.isEmpty {
                    Text(participantNames.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var categoryIcon: some View {
        ZStack {
            Circle()
                .fill((place?.category.accentColor ?? Color(.systemGray3)).opacity(0.16))
                .frame(width: 34, height: 34)

            Image(systemName: place?.category.systemImageName ?? "mappin.and.ellipse")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(place?.category.accentColor ?? Color(.systemGray))
        }
    }
}

private struct CalendarActivityRow: View {
    let activity: ActivityRecord

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: activity.activityType.systemImageName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 34, height: 34)
                .background(Color.green.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(activity.activityType.displayName)
                    .font(.headline)
                Text("\(ActivityFormat.distance(activity.distanceMeters)) · \(ActivityFormat.duration(activity.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct VisitCalendarMonthView: View {
    @Binding var displayedMonth: Date
    @Binding var selectedDate: Date

    let highlightedDates: Set<Date>
    let plannedDates: Set<Date>
    let activityDates: Set<Date>

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

        if activityDates.contains(day) {
            return .green
        }

        return .clear
    }

    @ViewBuilder
    private func dayBackground(for date: Date) -> some View {
        let day = calendar.startOfDay(for: date)

        if isSelected(date) {
            Circle().fill(Color.accentColor)
        } else if highlightedDates.contains(day) || plannedDates.contains(day) || activityDates.contains(day) {
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
