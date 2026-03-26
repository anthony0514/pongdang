import MapKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var spaceService = SpaceService()

    var body: some View {
        if !authService.hasResolvedAuthState {
            ZStack {
                DesignSystem.Backgrounds.lakeGradient.ignoresSafeArea()
                ProgressView()
            }
        } else if authService.currentUser == nil {
            LoginView()
                .environmentObject(authService)
        } else {
            MainTabView()
                .environmentObject(authService)
                .environmentObject(spaceService)
                .onAppear {
                    spaceService.fetchSpaces(for: authService.currentUser!.id)
                }
        }
    }
}

private struct MainTabView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var spaceService: SpaceService

    var body: some View {
        TabView {
            MapView()
                .environmentObject(spaceService)
                .environmentObject(authService)
                .tabItem {
                    Label("홈", systemImage: "map")
                }

            PlaceListView()
                .environmentObject(spaceService)
                .environmentObject(authService)
                .tabItem {
                    Label("리스트", systemImage: "list.bullet")
                }

            HistoryCalendarView()
                .environmentObject(spaceService)
                .environmentObject(authService)
                .tabItem {
                    Label("캘린더", systemImage: "calendar")
                }
        }
        .tint(DesignSystem.Colors.primary)
    }
}
