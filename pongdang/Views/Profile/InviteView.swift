import SwiftUI
import UIKit

struct InviteView: View {
    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService

    @State private var inviteCode = ""
    @State private var joinCode = ""
    @State private var copiedInviteCode = false
    @State private var toastMessage: String?

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { spaceService.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    spaceService.errorMessage = nil
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("초대하기") {
                Button("코드 생성") {
                    Task {
                        do {
                            inviteCode = try await spaceService.generateInviteCode(
                                for: spaceService.activeSpace!.id,
                                createdBy: authService.currentUser!.id
                            )
                        } catch {
                            spaceService.errorMessage = error.localizedDescription
                        }
                    }
                }

                if !inviteCode.isEmpty {
                    VStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.secondarySystemBackground))

                            Text(inviteCode)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .padding()
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 100)

                        Button(copiedInviteCode ? "복사됨" : "복사") {
                            UIPasteboard.general.string = inviteCode
                            copiedInviteCode = true
                            showToast("초대 코드를 복사했습니다.")
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                await MainActor.run {
                                    copiedInviteCode = false
                                }
                            }
                        }

                        Text("이 코드는 48시간 동안 유효합니다")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Section("참여하기") {
                TextField("6자리 코드 입력", text: $joinCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.center)

                Button("검색") {
                    Task {
                        let normalizedCode = joinCode
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .uppercased()

                        guard !normalizedCode.isEmpty else {
                            spaceService.errorMessage = "초대 코드를 입력해 주세요."
                            return
                        }

                        do {
                            try await spaceService.joinSpace(
                                with: normalizedCode,
                                userID: authService.currentUser!.id
                            )
                            joinCode = ""
                            showToast("스페이스에 참여했습니다.")
                        } catch {
                            spaceService.errorMessage = error.localizedDescription
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("멤버 초대")
        .navigationBarTitleDisplayMode(.inline)
        .alert("오류", isPresented: errorAlertBinding) {
            Button("확인") {
                spaceService.errorMessage = nil
            }
        } message: {
            Text(spaceService.errorMessage ?? "알 수 없는 오류가 발생했습니다.")
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
