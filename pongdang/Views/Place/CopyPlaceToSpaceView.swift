import SwiftUI

struct CopyPlaceToSpaceView: View {
    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService
    @StateObject private var placeService = PlaceService()
    @Environment(\.dismiss) private var dismiss

    let place: Place

    @State private var selectedSpaceID: String = ""
    @State private var localErrorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("공유할 장소") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(place.name)
                            .font(.headline)
                        Text(place.address)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
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

                        if let selectedSpace = selectedSpace {
                            Text("\(selectedSpace.name)에 동일한 장소를 새로 추가합니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
            .navigationTitle("다른 스페이스에 공유")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("공유") {
                        copyPlace()
                    }
                    .disabled(availableSpaces.isEmpty || selectedSpaceID.isEmpty || placeService.isLoading)
                }
            }
            .onAppear {
                initializeSelectedSpaceIfNeeded()
            }
            .onChange(of: spaceService.spaces) { _, _ in
                initializeSelectedSpaceIfNeeded()
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

    private var availableSpaces: [Space] {
        spaceService.spaces.filter { $0.id != place.spaceID }
    }

    private var selectedSpace: Space? {
        availableSpaces.first(where: { $0.id == selectedSpaceID })
    }

    private func initializeSelectedSpaceIfNeeded() {
        guard selectedSpaceID.isEmpty || !availableSpaces.contains(where: { $0.id == selectedSpaceID }) else { return }
        selectedSpaceID = availableSpaces.first?.id ?? ""
    }

    private func copyPlace() {
        guard let userID = authService.currentUser?.id else {
            localErrorMessage = "로그인 정보를 확인해 주세요"
            return
        }

        guard let targetSpaceID = selectedSpace?.id else {
            localErrorMessage = "공유할 스페이스를 선택해 주세요"
            return
        }

        Task {
            do {
                localErrorMessage = nil
                try await placeService.copyPlace(place, to: targetSpaceID, requestedBy: userID)
                dismiss()
            } catch {
                localErrorMessage = placeService.errorMessage ?? error.localizedDescription
            }
        }
    }
}
