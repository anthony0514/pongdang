import Combine
import Foundation

enum AppTab: Hashable {
    case map
    case list
    case calendar
    case profile
}

struct MapFocusRequest: Identifiable, Equatable {
    let id = UUID()
    let placeID: String
    let shouldPresentPlaceDetail: Bool
}

@MainActor
final class AppNavigationState: ObservableObject {
    @Published var selectedTab: AppTab = .map
    @Published var mapFocusRequest: MapFocusRequest?

    func showPlaceOnMap(placeID: String, presentDetail: Bool = false) {
        let request = MapFocusRequest(
            placeID: placeID,
            shouldPresentPlaceDetail: presentDetail
        )
        selectedTab = .map

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            mapFocusRequest = request
        }
    }
}
