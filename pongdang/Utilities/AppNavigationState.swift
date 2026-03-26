import Combine

enum AppTab: Hashable {
    case map
    case list
    case calendar
}

@MainActor
final class AppNavigationState: ObservableObject {
    @Published var selectedTab: AppTab = .map
    @Published var focusedPlaceID: String?

    func showPlaceOnMap(placeID: String) {
        focusedPlaceID = placeID
        selectedTab = .map
    }
}
