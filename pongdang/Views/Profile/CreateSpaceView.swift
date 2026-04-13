import SwiftUI

struct CreateSpaceView: View {
    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var spaceName = ""
    @State private var isCreating = false

    private var trimmedSpaceName: String {
        spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { spaceService.errorMessage != nil },
            set: { if !$0 { spaceService.errorMessage = nil } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("새 스페이스")
                    .font(.headline)
                if authService.isGuestUser {
                    Text("게스트 모드에서는 스페이스를 만들 수 없습니다.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("스페이스 이름", text: $spaceName)
                .onChange(of: spaceName) { _, newValue in
                    spaceName = InputSanitizer.sanitize(newValue, as: .spaceName)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(authService.isGuestUser || isCreating)

            VStack(spacing: 10) {
                Button("만들기") {
                    Task {
                        isCreating = true
                        do {
                            let space = try await spaceService.createSpace(
                                name: InputSanitizer.sanitize(trimmedSpaceName, as: .spaceName),
                                createdBy: authService.currentUser!.id
                            )
                            spaceService.setActiveSpace(space)
                            dismiss()
                        } catch {
                            spaceService.errorMessage = error.localizedDescription
                        }
                        isCreating = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(trimmedSpaceName.isEmpty || authService.isGuestUser || isCreating)

                Button("취소", role: .cancel) {
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .disabled(isCreating)
            }
        }
        .padding(24)
        .overlay {
            if isCreating {
                Color.clear
                    .ignoresSafeArea()
                    .overlay(ProgressView())
            }
        }
        .presentationDetents([.height(240)])
        .presentationDragIndicator(.visible)
        .alert("오류", isPresented: errorAlertBinding) {
            Button("확인") { spaceService.errorMessage = nil }
        } message: {
            Text(spaceService.errorMessage ?? "알 수 없는 오류가 발생했습니다.")
        }
    }
}
