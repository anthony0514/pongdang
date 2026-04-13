import SwiftUI

struct BatchSharePlacesView: View {
    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService
    @StateObject private var placeService = PlaceService()
    @Environment(\.dismiss) private var dismiss

    let places: [Place]
    let onComplete: () -> Void

    @State private var selectedSpaceID: String = ""
    @State private var localErrorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("선택한 장소") {
                    Text("\(places.count)개 장소를 다른 스페이스에 복사합니다.")
                        .font(.subheadline)
                }

                Section("대상 스페이스") {
                    if availableSpaces.isEmpty {
                        Text("복사할 수 있는 다른 스페이스가 없습니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("스페이스", selection: $selectedSpaceID) {
                            ForEach(availableSpaces) { space in
                                Text(space.name).tag(space.id)
                            }
                        }
                    }
                }

                Section {
                    Text("방문 기록은 함께 복사되지 않고, 복사된 장소는 미방문 상태로 시작합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let localErrorMessage, !localErrorMessage.isEmpty {
                    Section {
                        Text(localErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("일괄 공유")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("공유") {
                        sharePlaces()
                    }
                    .disabled(places.isEmpty || availableSpaces.isEmpty || selectedSpaceID.isEmpty || placeService.isLoading)
                }
            }
            .onAppear {
                initializeSelectionIfNeeded()
            }
            .onChange(of: spaceService.spaces) { _, _ in
                initializeSelectionIfNeeded()
            }
            .overlay {
                if placeService.isLoading {
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

    private var sourceSpaceID: String? {
        Set(places.map(\.spaceID)).first
    }

    private var availableSpaces: [Space] {
        guard let sourceSpaceID else { return [] }
        return spaceService.spaces.filter { $0.id != sourceSpaceID }
    }

    private func initializeSelectionIfNeeded() {
        guard selectedSpaceID.isEmpty || !availableSpaces.contains(where: { $0.id == selectedSpaceID }) else { return }
        selectedSpaceID = availableSpaces.first?.id ?? ""
    }

    private func sharePlaces() {
        guard let userID = authService.currentUser?.id else {
            localErrorMessage = "로그인 정보를 확인해 주세요"
            return
        }

        Task {
            do {
                localErrorMessage = nil
                try await placeService.copyPlaces(places, to: selectedSpaceID, requestedBy: userID)
                onComplete()
                dismiss()
            } catch {
                localErrorMessage = placeService.errorMessage ?? error.localizedDescription
            }
        }
    }
}
