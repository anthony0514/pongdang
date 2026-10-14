import SwiftUI

struct HealthWorkoutPickerView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var activityService = ActivityService()

    let space: Space

    @State private var importer = HealthWorkoutImporter()
    @State private var workouts: [HealthWorkoutImporter.WorkoutSummary] = []
    @State private var sharedWorkoutIDs: Set<String> = []
    @State private var isLoadingWorkouts = true
    @State private var sharingWorkoutID: String?
    @State private var workoutToShare: HealthWorkoutImporter.WorkoutSummary?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if !HealthWorkoutImporter.isAvailable {
                    ContentUnavailableView(
                        "건강 데이터를 쓸 수 없어요",
                        systemImage: "heart.slash",
                        description: Text("이 기기에서는 건강 앱을 사용할 수 없어요. 아이폰에서 시도해 주세요.")
                    )
                } else if isLoadingWorkouts {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if workouts.isEmpty {
                    ContentUnavailableView(
                        "가져올 운동이 없어요",
                        systemImage: "figure.walk",
                        description: Text("최근 90일 동안 경로가 기록된 운동이 없어요. 건강 앱에서 운동 접근을 허용했는지도 확인해 주세요.")
                    )
                } else {
                    Section {
                        ForEach(workouts) { workout in
                            Button {
                                workoutToShare = workout
                            } label: {
                                WorkoutRow(
                                    workout: workout,
                                    isShared: sharedWorkoutIDs.contains(workout.id),
                                    isSharing: sharingWorkoutID == workout.id
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(sharedWorkoutIDs.contains(workout.id) || sharingWorkoutID != nil)
                        }
                    } footer: {
                        Text("경로가 기록된 최근 90일 운동이에요. 고른 운동만 \(space.name)에 공유돼요.")
                    }
                }
            }
            .navigationTitle("건강에서 가져오기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                }
            }
            .confirmationDialog(
                "이 운동을 공유할까요?",
                isPresented: shareDialogBinding,
                titleVisibility: .visible,
                presenting: workoutToShare
            ) { workout in
                Button("\(space.name)에 공유") {
                    share(workout)
                }
                Button("취소", role: .cancel) {}
            } message: { _ in
                Text("경로와 거리, 시간이 스페이스 멤버에게 보여요.")
            }
            .task {
                await loadWorkouts()
            }
        }
    }

    private var shareDialogBinding: Binding<Bool> {
        Binding(
            get: { workoutToShare != nil },
            set: { if !$0 { workoutToShare = nil } }
        )
    }

    private func loadWorkouts() async {
        guard HealthWorkoutImporter.isAvailable else { return }
        isLoadingWorkouts = true
        defer { isLoadingWorkouts = false }

        do {
            try await importer.requestAuthorization()
            workouts = try await importer.recentWorkoutsWithRoutes()
            if let userID = authService.currentUser?.id {
                sharedWorkoutIDs = await activityService.sharedWorkoutIDs(spaceID: space.id, userID: userID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func share(_ workout: HealthWorkoutImporter.WorkoutSummary) {
        guard let userID = authService.currentUser?.id else { return }
        sharingWorkoutID = workout.id
        errorMessage = nil

        Task {
            defer { sharingWorkoutID = nil }
            do {
                let route = try await importer.loadRoute(for: workout.workout)
                try await activityService.shareWorkout(workout, route: route, spaceID: space.id, requestedBy: userID)
                sharedWorkoutIDs.insert(workout.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct WorkoutRow: View {
    let workout: HealthWorkoutImporter.WorkoutSummary
    let isShared: Bool
    let isSharing: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: workout.activityType.systemImageName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 36, height: 36)
                .background(Color.green.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(workout.activityType.displayName)
                    .font(.headline)
                Text("\(Self.dateFormatter.string(from: workout.startedAt)) · \(ActivityFormat.duration(workout.endedAt.timeIntervalSince(workout.startedAt)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isSharing {
                ProgressView()
            } else if isShared {
                Label("공유됨", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 (E) a h:mm"
        return formatter
    }()
}
