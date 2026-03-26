import Foundation
import GoogleSignIn
import FirebaseAuth
import UIKit

struct GoogleSignInHelper {
    static func signIn() async throws -> (credential: AuthCredential, name: String, photoURL: String?) {
        guard let rootVC = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?.rootViewController
        else {
            throw URLError(.cannotFindHost)
        }

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
        let user = result.user
        guard let idToken = user.idToken?.tokenString else {
            throw URLError(.badServerResponse)
        }
        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: user.accessToken.tokenString
        )
        let name = user.profile?.name ?? "사용자"
        let photoURL = user.profile?.imageURL(withDimension: 200)?.absoluteString
        return (credential, name, photoURL)
    }
}
