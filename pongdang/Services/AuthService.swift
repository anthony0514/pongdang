import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore

@MainActor
class AuthService: ObservableObject {
    @Published var firebaseUser: FirebaseAuth.User?
    @Published var currentUser: AppUser?
    @Published var isLoading: Bool = false
    @Published var hasResolvedAuthState: Bool = false
    @Published var errorMessage: String?

    private var authStateHandle: AuthStateDidChangeListenerHandle?
    private let db = Firestore.firestore()

    init() {
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.firebaseUser = user
                if let user = user {
                    await self?.fetchOrCreateUser(uid: user.uid, name: user.displayName ?? "사용자", photoURL: user.photoURL?.absoluteString)
                } else {
                    self?.currentUser = nil
                }
                self?.hasResolvedAuthState = true
            }
        }
    }

    deinit {
        if let handle = authStateHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    func signOut() {
        try? Auth.auth().signOut()
    }

    func signInWithApple(credential: AuthCredential) async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await Auth.auth().signIn(with: credential)
            await fetchOrCreateUser(uid: result.user.uid, name: result.user.displayName ?? "사용자", photoURL: result.user.photoURL?.absoluteString)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func signInWithGoogle(credential: AuthCredential, name: String, photoURL: String?) async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await Auth.auth().signIn(with: credential)
            await fetchOrCreateUser(uid: result.user.uid, name: name, photoURL: photoURL)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func updateHomeLocation(address: String?, latitude: Double?, longitude: Double?) async {
        guard let currentUser else { return }

        isLoading = true
        errorMessage = nil

        do {
            try await db.collection("users").document(currentUser.id).updateData([
                "homeAddress": address as Any,
                "homeLatitude": latitude as Any,
                "homeLongitude": longitude as Any
            ])

            self.currentUser?.homeAddress = address
            self.currentUser?.homeLatitude = latitude
            self.currentUser?.homeLongitude = longitude
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func updateDisplayName(userID: String, name: String) async throws {
        try await db.collection("users").document(userID).updateData([
            "name": name
        ])

        currentUser?.name = name
    }

    private func fetchOrCreateUser(uid: String, name: String, photoURL: String?) async {
        let ref = db.collection("users").document(uid)
        do {
            let snapshot = try await ref.getDocument()
            if snapshot.exists, let data = try? snapshot.data(as: AppUser.self) {
                self.currentUser = data
            } else {
                let newUser = AppUser(
                    id: uid,
                    name: name,
                    profileImageURL: photoURL,
                    homeAddress: nil,
                    homeLatitude: nil,
                    homeLongitude: nil,
                    createdAt: Date()
                )
                try? ref.setData(from: newUser)
                self.currentUser = newUser
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
