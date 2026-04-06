import MapKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appLocationStore: AppLocationStore
    @StateObject private var spaceService = SpaceService()
    @StateObject private var navigationState = AppNavigationState()

    var body: some View {
        if !authService.hasResolvedAuthState {
            AppLoadingView()
        } else if authService.currentUser == nil {
            LoginView()
                .environmentObject(authService)
        } else if !appLocationStore.hasResolvedStartupRequest {
            AppLoadingView()
        } else {
            MainTabView()
                .environmentObject(authService)
                .environmentObject(appLocationStore)
                .environmentObject(spaceService)
                .environmentObject(navigationState)
                .onAppear {
                    spaceService.fetchSpaces(for: authService.currentUser!.id)
                }
        }
    }
}

private struct AppLoadingView: View {
    var body: some View {
        ZStack {
            DesignSystem.Backgrounds.lakeGradient
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image("app_logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 148, height: 148)
                    .shadow(color: Color.black.opacity(0.16), radius: 18, y: 8)

                ProgressView()
                    .tint(.white)
            }
        }
    }
}

private struct MainTabView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appLocationStore: AppLocationStore
    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var navigationState: AppNavigationState

    var body: some View {
        TabView(selection: $navigationState.selectedTab) {
            MapView()
                .environmentObject(appLocationStore)
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

            NavigationStack {
                SettingsView()
                    .environmentObject(spaceService)
                    .environmentObject(authService)
            }
            .tag(AppTab.profile)
            .tabItem {
                Label("프로필", systemImage: "person")
            }
        }
        .tint(DesignSystem.Colors.primary)
    }
}
