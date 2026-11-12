import SwiftUI
import CoreLocation
import Combine

@MainActor
final class AppLocationStore: NSObject, ObservableObject {
    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published var hasResolvedStartupRequest = false

    /// The longest the launch screen waits for a fresh location when the device
    /// has none saved. The map opens either way and moves once a fix arrives.
    private static let startupWait: Duration = .seconds(1)
    /// A saved location this recent is good enough to open the map on.
    private static let maxCachedLocationAge: TimeInterval = 7 * 24 * 60 * 60

    private let locationManager = CLLocationManager()
    private var isAwaitingInitialLocation = false
    private var startupTimeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        locationManager.delegate = self
        // City-block accuracy arrives in well under a second; "best" waited on GPS,
        // which kept the launch screen up for several seconds indoors.
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        requestStartupLocation()
    }

    func requestStartupLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            // The permission prompt is on screen; wait for the user's answer.
            isAwaitingInitialLocation = true
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            requestLocationWithoutBlockingStartup()
        case .denied, .restricted:
            finishStartup()
        @unknown default:
            finishStartup()
        }
    }

    /// Opens the map on the last known location right away, or after at most
    /// `startupWait`, while a fresh location is requested in the background.
    private func requestLocationWithoutBlockingStartup() {
        if let cached = locationManager.location,
           -cached.timestamp.timeIntervalSinceNow < Self.maxCachedLocationAge {
            currentCoordinate = cached.coordinate
            finishStartup()
        } else if !hasResolvedStartupRequest {
            isAwaitingInitialLocation = true
            startupTimeoutTask?.cancel()
            startupTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.startupWait)
                guard !Task.isCancelled else { return }
                self?.finishStartup()
            }
        }
        locationManager.requestLocation()
    }

    private func finishStartup() {
        isAwaitingInitialLocation = false
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        hasResolvedStartupRequest = true
    }
}

extension AppLocationStore: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .notDetermined:
            break
        case .authorizedAlways, .authorizedWhenInUse:
            requestLocationWithoutBlockingStartup()
        case .denied, .restricted:
            finishStartup()
        @unknown default:
            finishStartup()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentCoordinate = locations.last?.coordinate
        if isAwaitingInitialLocation {
            finishStartup()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if isAwaitingInitialLocation {
            finishStartup()
        }
    }
}
