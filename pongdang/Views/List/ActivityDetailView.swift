import MapKit
import SwiftUI

struct ActivityDetailView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var spaceService: SpaceService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var activityService = ActivityService()

    let activity: ActivityRecord

    @State private var sharerName = " "
    @State private var showingDeleteAlert = false
    @State private var errorMessage: String?

    private var coordinates: [CLLocationCoordinate2D] {
        activity.routeCoordinates
    }

    private var canDelete: Bool {
        let userID = authService.currentUser?.id
        return userID == activity.createdBy || userID == spaceService.activeSpace?.createdBy
    }

    var body: some View {
        List {
            Section {
                routeMap
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            Section {
                statRow("종류", value: activity.activityType.displayName, systemImage: activity.activityType.systemImageName)
                statRow("시간", value: timeRangeText, systemImage: "clock")
                statRow("거리", value: ActivityFormat.distance(activity.distanceMeters), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                statRow("소요 시간", value: ActivityFormat.duration(activity.duration), systemImage: "timer")
                if let elevationGain = activity.elevationGainMeters {
                    statRow("오르막", value: "\(Int(elevationGain.rounded()))m", systemImage: "mountain.2")
                }
                statRow("공유한 사람", value: sharerName, systemImage: "person")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(activity.activityType.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canDelete {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("삭제", role: .destructive) {
                            showingDeleteAlert = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("이 운동 기록을 삭제할까요?", isPresented: $showingDeleteAlert) {
            Button("삭제", role: .destructive) {
                deleteActivity()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("건강 앱의 원본 기록은 그대로 남아요.")
        }
        .task(id: activity.createdBy) {
            if activity.createdBy == authService.currentUser?.id, let name = authService.currentUser?.name {
                sharerName = name
            } else {
                sharerName = await UserNameLoader.name(for: activity.createdBy)
            }
        }
    }

    private var routeMap: some View {
        Map(initialPosition: .rect(Self.boundingRect(for: coordinates))) {
            MapPolyline(coordinates: coordinates)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))

            if let start = coordinates.first {
                Annotation("출발", coordinate: start) {
                    Circle().fill(.green).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }

            if let end = coordinates.last, coordinates.count > 1 {
                Annotation("도착", coordinate: end) {
                    Circle().fill(.red).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }

    private func statRow(_ title: String, value: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private var timeRangeText: String {
        "\(Self.dateFormatter.string(from: activity.startedAt)) ~ \(Self.timeFormatter.string(from: activity.endedAt))"
    }

    private func deleteActivity() {
        Task {
            do {
                try await activityService.deleteActivity(activity)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func boundingRect(for coordinates: [CLLocationCoordinate2D]) -> MKMapRect {
        let points = coordinates.map(MKMapPoint.init)
        guard let first = points.first else { return .world }

        var rect = MKMapRect(origin: first, size: MKMapSize(width: 0, height: 0))
        for point in points.dropFirst() {
            rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
        }

        let padding = max(rect.size.width, rect.size.height) * 0.2 + 300
        return rect.insetBy(dx: -padding, dy: -padding)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 (E) a h:mm"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "a h:mm"
        return formatter
    }()
}
