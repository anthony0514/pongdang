import AuthenticationServices
import Combine
import CryptoKit
import FirebaseAuth
import Foundation
import Security
import UIKit

@MainActor
final class AppleSignInCoordinator: NSObject, ObservableObject {
    private var currentNonce: String?
    private var presentationAnchor: ASPresentationAnchor?
    private var continuation: CheckedContinuation<AuthCredential, Error>?

    func startSignIn(anchor: ASPresentationAnchor) async throws -> AuthCredential {
        let nonce = randomNonceString()
        currentNonce = nonce
        presentationAnchor = anchor

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = sha256(nonce)

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)

        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            let randoms: [UInt8] = (0..<16).map { _ in
                var random: UInt8 = 0
                let errorCode = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
                precondition(errorCode == errSecSuccess, "Nonce generation failed with OSStatus \(errorCode)")
                return random
            }

            randoms.forEach { random in
                guard remainingLength > 0 else { return }
                if random < UInt8(charset.count) {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }

        return result
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.map { String(format: "%02x", $0) }.joined()
    }

    private func resume(with result: Result<AuthCredential, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        currentNonce = nil
        presentationAnchor = nil
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            resume(with: .failure(URLError(.badServerResponse)))
            return
        }

        guard let nonce = currentNonce else {
            resume(with: .failure(URLError(.userAuthenticationRequired)))
            return
        }

        guard let identityToken = appleIDCredential.identityToken,
              let idTokenString = String(data: identityToken, encoding: .utf8) else {
            resume(with: .failure(URLError(.cannotDecodeRawData)))
            return
        }

        let credential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: nonce,
            fullName: appleIDCredential.fullName
        )
        resume(with: .success(credential))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        resume(with: .failure(error))
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let presentationAnchor {
            return presentationAnchor
        }

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            return ASPresentationAnchor(windowScene: windowScene)
        }

        fatalError("No window scene available for Apple Sign In presentation anchor.")
    }
}
