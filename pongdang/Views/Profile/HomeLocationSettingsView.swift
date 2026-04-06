import SwiftUI
import Combine
import CoreLocation
import MapKit

struct HomeLocationSettingsView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var spaceService: SpaceService
    @Environment(\.dismiss) private var dismiss

    @StateObject private var locationManager = HomeLocationManager()

    @State private var homeAddress = ""
    @State private var homeLatitude: Double?
    @State private var homeLongitude: Double?
    @State private var localErrorMessage: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                if let localErrorMessage, !localErrorMessage.isEmpty {
                    Section {
                        Text(localErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("내 집 위치") {
                    if let savedHomeSummary {
                        Text(savedHomeSummary)
                            .font(.subheadline)
                    } else {
                        Text("아직 등록된 집 위치가 없습니다.")
                            .foregroundStyle(.secondary)
                    }

                    Button("현재 위치로 집 위치 설정") {
                        locationManager.requestHomeLocation()
                    }

                    TextField("집 주소 메모", text: $homeAddress)

                    if let homeLatitude, let homeLongitude {
                        Text("좌표: \(homeLatitude.formatted(.number.precision(.fractionLength(4)))), \(homeLongitude.formatted(.number.precision(.fractionLength(4))))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("집 위치 저장") {
                        saveHomeLocation()
                    }
                    .disabled(homeLatitude == nil || homeLongitude == nil || isSaving)

                    if authService.currentUser?.homeLatitude != nil, authService.currentUser?.homeLongitude != nil {
                        Button("집 위치 삭제", role: .destructive) {
                            clearHomeLocation()
                        }
                    }
                }

                if let activeSpace = spaceService.activeSpace {
                    Section("현재 스페이스 공개 설정") {
                        Toggle("이 스페이스에 내 집 위치 공개", isOn: homeVisibilityBinding(for: activeSpace))
                            .disabled(!hasSavedHomeLocation)

                        if !hasSavedHomeLocation {
                            Text("집 위치를 먼저 저장해야 공개할 수 있습니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("내 집 위치")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                syncFromCurrentUser()
            }
            .onChange(of: authService.currentUser?.id) { _, _ in
                syncFromCurrentUser()
            }
            .onReceive(locationManager.$resolvedAddress) { resolvedAddress in
                guard let resolvedAddress, !resolvedAddress.isEmpty else { return }
                homeAddress = resolvedAddress
            }
            .onReceive(locationManager.$selectedCoordinate) { coordinate in
                homeLatitude = coordinate?.latitude
                homeLongitude = coordinate?.longitude
            }
            .overlay {
                if authService.isLoading || isSaving || locationManager.isLoading {
                    ZStack {
                        Color.black.opacity(0.12)
                            .ignoresSafeArea()
                        ProgressView()
                            .padding(20)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }

    private var savedHomeSummary: String? {
        let address = authService.currentUser?.homeAddress
        if let address, !address.isEmpty {
            return address
        }

        guard
            let lat = authService.currentUser?.homeLatitude,
            let lng = authService.currentUser?.homeLongitude
        else {
            return nil
        }

        return "\(lat.formatted(.number.precision(.fractionLength(4)))), \(lng.formatted(.number.precision(.fractionLength(4))))"
    }

    private var hasSavedHomeLocation: Bool {
        authService.currentUser?.homeLatitude != nil && authService.currentUser?.homeLongitude != nil
    }

    private func syncFromCurrentUser() {
        homeAddress = authService.currentUser?.homeAddress ?? ""
        homeLatitude = authService.currentUser?.homeLatitude
        homeLongitude = authService.currentUser?.homeLongitude
    }

    private func saveHomeLocation() {
        Task {
            isSaving = true
            localErrorMessage = nil
            await authService.updateHomeLocation(
                address: homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : homeAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                latitude: homeLatitude,
                longitude: homeLongitude
            )

            if let errorMessage = authService.errorMessage {
                localErrorMessage = errorMessage
            }
            isSaving = false
        }
    }

    private func clearHomeLocation() {
        Task {
            isSaving = true
            localErrorMessage = nil
            await authService.updateHomeLocation(address: nil, latitude: nil, longitude: nil)
            syncFromCurrentUser()
            if let errorMessage = authService.errorMessage {
                localErrorMessage = errorMessage
            }
            isSaving = false
        }
    }

    private func homeVisibilityBinding(for space: Space) -> Binding<Bool> {
        Binding(
            get: {
                guard let userID = authService.currentUser?.id else { return false }
                return spaceService.activeSpace?.sharedHomeMemberIDs.contains(userID) ?? space.sharedHomeMemberIDs.contains(userID)
            },
            set: { isVisible in
                guard let userID = authService.currentUser?.id else { return }
                Task {
                    do {
                        try await spaceService.setHomeVisibility(spaceID: space.id, userID: userID, isVisible: isVisible)
                    } catch {
                        localErrorMessage = error.localizedDescription
                    }
                }
            }
        )
    }
}

@MainActor
final class HomeLocationManager: NSObject, ObservableObject {
    @Published var selectedCoordinate: CLLocationCoordinate2D?
    @Published var resolvedAddress: String?
    @Published var isLoading = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestHomeLocation() {
        isLoading = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            isLoading = false
        @unknown default:
            isLoading = false
        }
    }
}

extension HomeLocationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if isLoading {
                manager.requestLocation()
            }
        case .denied, .restricted:
            isLoading = false
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            isLoading = false
            return
        }

        selectedCoordinate = location.coordinate

        Task { @MainActor in
            let request = MKReverseGeocodingRequest(location: location)
            let mapItem = try? await request?.mapItems.first
            resolvedAddress = mapItem?.address?.fullAddress ?? mapItem?.address?.shortAddress
            isLoading = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        isLoading = false
    }
}
