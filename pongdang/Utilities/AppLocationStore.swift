import SwiftUI
import CoreLocation
import Combine

@MainActor
final class AppLocationStore: NSObject, ObservableObject {
    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published var hasResolvedStartupRequest = false

    private let locationManager = CLLocationManager()
    private var isAwaitingInitialLocation = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        requestStartupLocation()
    }

    func requestStartupLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            isAwaitingInitialLocation = true
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            isAwaitingInitialLocation = true
            locationManager.requestLocation()
        case .denied, .restricted:
            isAwaitingInitialLocation = false
            hasResolvedStartupRequest = true
        @unknown default:
            isAwaitingInitialLocation = false
            hasResolvedStartupRequest = true
        }
    }
}

extension AppLocationStore: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .notDetermined:
            break
        case .authorizedAlways, .authorizedWhenInUse:
            isAwaitingInitialLocation = true
            manager.requestLocation()
        case .denied, .restricted:
            isAwaitingInitialLocation = false
            hasResolvedStartupRequest = true
        @unknown default:
            isAwaitingInitialLocation = false
            hasResolvedStartupRequest = true
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentCoordinate = locations.last?.coordinate
        if isAwaitingInitialLocation {
            isAwaitingInitialLocation = false
            hasResolvedStartupRequest = true
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if isAwaitingInitialLocation {
            isAwaitingInitialLocation = false
            hasResolvedStartupRequest = true
        }
    }
}
