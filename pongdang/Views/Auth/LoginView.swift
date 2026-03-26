import AuthenticationServices
import FirebaseAuth
import SwiftUI
import UIKit

struct LoginView: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var appleCoordinator = AppleSignInCoordinator()

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("퐁당")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .shadow(color: Color.white.opacity(0.08), radius: 6, y: 2)

                Text("우리 둘만의 장소 일기")
                    .font(.subheadline)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .padding(.top, 80)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    handleAppleSignIn()
                } label: {
                    Text("Apple로 로그인")
                        .font(.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .pondangGlassCard(cornerRadius: 18)
                }
                .disabled(authService.isLoading)

                Button {
                    handleGoogleSignIn()
                } label: {
                    Text("Google로 로그인")
                        .font(.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .pondangGlassCard(cornerRadius: 18)
                }
                .disabled(authService.isLoading)

                if authService.isLoading {
                    ProgressView("로그인 중...")
                        .progressViewStyle(.circular)
                        .tint(DesignSystem.Colors.accent)
                        .padding(.top, 8)
                }
            }
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pondangScreenBackground()
        .alert("로그인 오류", isPresented: errorAlertBinding) {
            Button("확인", role: .cancel) {
                authService.errorMessage = nil
            }
        } message: {
            Text(authService.errorMessage ?? "알 수 없는 오류가 발생했습니다.")
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { authService.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    authService.errorMessage = nil
                }
            }
        )
    }

    private func handleAppleSignIn() {
        Task {
            do {
                guard let anchor = presentationAnchor else {
                    await MainActor.run {
                        authService.errorMessage = "로그인 화면을 표시할 수 없습니다."
                    }
                    return
                }

                let credential = try await appleCoordinator.startSignIn(anchor: anchor)
                await authService.signInWithApple(credential: credential)
            } catch {
                await MainActor.run {
                    authService.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleGoogleSignIn() {
        Task {
            do {
                let result = try await GoogleSignInHelper.signIn()
                await authService.signInWithGoogle(
                    credential: result.credential,
                    name: result.name,
                    photoURL: result.photoURL
                )
            } catch {
                await MainActor.run {
                    authService.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var presentationAnchor: ASPresentationAnchor? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

#Preview {
    LoginView()
        .environmentObject(AuthService())
}
