import SwiftUI

struct CreateSpaceView: View {
    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var spaceName = ""

    private var trimmedSpaceName: String {
        spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("스페이스 이름", text: $spaceName)

                Button("만들기") {
                    Task {
                        do {
                            let space = try await spaceService.createSpace(
                                name: trimmedSpaceName,
                                createdBy: authService.currentUser!.id
                            )
                            spaceService.setActiveSpace(space)
                            dismiss()
                        } catch {
                            spaceService.errorMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(trimmedSpaceName.isEmpty)
            }
            .navigationTitle("새 스페이스")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") {
                        dismiss()
                    }
                }
            }
            .overlay {
                if spaceService.isLoading {
                    ZStack {
                        Color.black.opacity(0.1)
                            .ignoresSafeArea()
                        ProgressView()
                    }
                }
            }
        }
    }
}
