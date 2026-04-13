import SwiftUI

struct InviteView: View {
    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService

    @State private var joinCode = ""
    @State private var toastMessage: String?
    @State private var localErrorMessage: String?
    @State private var isJoining = false

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { localErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    localErrorMessage = nil
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("참여하기") {
                TextField("6자리 코드 입력", text: $joinCode)
                    .onChange(of: joinCode) { _, newValue in
                        joinCode = InputSanitizer.sanitize(newValue.uppercased(), as: .inviteCode)
                    }
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.center)

                Button {
                    Task {
                        isJoining = true
                        localErrorMessage = nil
                        let normalizedCode = joinCode
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .uppercased()

                        guard !normalizedCode.isEmpty else {
                            localErrorMessage = "초대 코드를 입력해 주세요."
                            isJoining = false
                            return
                        }

                        do {
                            let result = try await spaceService.joinSpace(
                                with: normalizedCode,
                                userID: authService.currentUser!.id
                            )
                            joinCode = ""
                            showToast(
                                result == .joined
                                ? "스페이스에 참여했습니다."
                                : "이미 참여 중인 스페이스입니다."
                            )
                        } catch {
                            localErrorMessage = error.localizedDescription
                        }
                        isJoining = false
                    }
                } label: {
                    Text("참여하기")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.plain)
                .disabled(isJoining)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                Text("초대 코드는 스페이스 관리 화면에서만 생성되며 10분 후 만료됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("스페이스 참여")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            localErrorMessage = nil
        }
        .alert("오류", isPresented: errorAlertBinding) {
            Button("확인") {
                localErrorMessage = nil
            }
        } message: {
            Text(localErrorMessage ?? "알 수 없는 오류가 발생했습니다.")
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastMessage != nil)
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            await MainActor.run {
                if toastMessage == message {
                    toastMessage = nil
                }
            }
        }
    }
}
