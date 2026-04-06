import Combine
import FirebaseCore
import GoogleSignIn
import SwiftUI
import UserNotifications

enum AppPreferences {
    static let localNotificationsEnabledKey = "localNotificationsEnabled"
}

enum LocalNotificationManager {
    static func requestAuthorizationIfNeeded() async -> Bool {
        guard UserDefaults.standard.bool(forKey: AppPreferences.localNotificationsEnabledKey) else {
            return false
        }

        let settings = await notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return await requestAuthorization()
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    static func schedule(title: String, body: String) {
        guard UserDefaults.standard.bool(forKey: AppPreferences.localNotificationsEnabledKey) else {
            return
        }

        Task {
            guard await requestAuthorizationIfNeeded() else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            try? await add(request)
        }
    }

    private static func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

@main
struct pongdangApp: App {
    @StateObject private var authService = AuthService()
    @StateObject private var pendingShareStore = PendingShareStore()
    @StateObject private var appLocationStore = AppLocationStore()

    init() {
        UserDefaults.standard.register(defaults: [
            AppPreferences.localNotificationsEnabledKey: true
        ])

        FirebaseApp.configure()
        if let clientID = FirebaseApp.app()?.options.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }

        if UserDefaults.standard.bool(forKey: AppPreferences.localNotificationsEnabledKey) {
            Task {
                _ = await LocalNotificationManager.requestAuthorizationIfNeeded()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authService)
                .environmentObject(pendingShareStore)
                .environmentObject(appLocationStore)
                .onOpenURL { url in
                    // Google Sign-In 처리
                    if GIDSignIn.sharedInstance.handle(url) { return }

                    // Share Extension에서 pongdang://addplace 로 열린 경우
                    if url.scheme == "pongdang", url.host == "addplace" {
                        pendingShareStore.loadFromAppGroup()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    // 앱이 백그라운드에서 복귀할 때도 확인 (앱이 이미 실행 중인 경우)
                    pendingShareStore.loadFromAppGroup()
                }
        }
    }
}

// MARK: - PendingShareStore

/// Share Extension에서 저장한 장소 데이터를 메인 앱으로 전달하는 스토어
@MainActor
final class PendingShareStore: ObservableObject {
    @Published var pendingLocation: PendingSharedLocation?

    private let appGroupID = "group.anthony.pongdang"
    private let pendingShareKey = "pendingShareLocation"

    func loadFromAppGroup() {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: pendingShareKey),
              let location = try? JSONDecoder().decode(PendingSharedLocation.self, from: data)
        else { return }

        pendingLocation = location

        // 읽은 후 즉시 삭제 (중복 팝업 방지)
        defaults.removeObject(forKey: pendingShareKey)
        defaults.synchronize()
    }

    func clearPending() {
        pendingLocation = nil
    }
}

// MARK: - PendingSharedLocation

struct PendingSharedLocation: Codable, Equatable {
    var name: String?
    var latitude: Double?
    var longitude: Double?
    var address: String?
    var sourceURL: String?
}
