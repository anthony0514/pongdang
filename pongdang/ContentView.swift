import MapKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var spaceService = SpaceService()
    @StateObject private var navigationState = AppNavigationState()

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
                .environmentObject(navigationState)
                .onAppear {
                    spaceService.fetchSpaces(for: authService.currentUser!.id)
                }
        }
    }
}

private struct MainTabView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var navigationState: AppNavigationState

    var body: some View {
        TabView(selection: $navigationState.selectedTab) {
            MapView()
                .environmentObject(spaceService)
                .environmentObject(authService)
                .environmentObject(navigationState)
                .tag(AppTab.map)
                .tabItem {
                    Label("홈", systemImage: "map")
                }

            PlaceListView()
                .environmentObject(spaceService)
                .environmentObject(authService)
                .environmentObject(navigationState)
                .tag(AppTab.list)
                .tabItem {
                    Label("리스트", systemImage: "list.bullet")
                }

            HistoryCalendarView()
                .environmentObject(spaceService)
                .environmentObject(authService)
                .environmentObject(navigationState)
                .tag(AppTab.calendar)
                .tabItem {
                    Label("캘린더", systemImage: "calendar")
                }
        }
        .tint(DesignSystem.Colors.primary)
    }
}
