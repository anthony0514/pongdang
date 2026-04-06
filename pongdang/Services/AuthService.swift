import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore

@MainActor
class AuthService: ObservableObject {
    private static let guestUserID = "guest-user"

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

    var isGuestUser: Bool {
        currentUser?.id == Self.guestUserID
    }

    func continueAsGuest() {
        errorMessage = nil
        firebaseUser = nil
        currentUser = AppUser(
            id: Self.guestUserID,
            name: "게스트",
            profileImageURL: nil,
            homeAddress: nil,
            homeLatitude: nil,
            homeLongitude: nil,
            createdAt: Date()
        )
        hasResolvedAuthState = true
    }

    func signOut() {
        try? Auth.auth().signOut()
        firebaseUser = nil
        currentUser = nil
        errorMessage = nil
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
        if isGuestUser {
            currentUser?.name = name
            return
        }

        try await db.collection("users").document(userID).updateData([
            "name": name
        ])

        currentUser?.name = name
    }

    func deleteCurrentAccount() async throws {
        if isGuestUser {
            signOut()
            return
        }

        guard let firebaseUser, let currentUser else { return }

        isLoading = true
        errorMessage = nil

        do {
            let userID = currentUser.id

            let createdSpacesSnapshot = try await db.collection("spaces")
                .whereField("createdBy", isEqualTo: userID)
                .getDocuments()

            let createdSpaceIDs = Set(createdSpacesSnapshot.documents.map(\.documentID))

            for spaceDocument in createdSpacesSnapshot.documents {
                let spaceID = spaceDocument.documentID

                let placesSnapshot = try await db.collection("places")
                    .whereField("spaceID", isEqualTo: spaceID)
                    .getDocuments()

                for placeDocument in placesSnapshot.documents {
                    let recordSnapshot = try await db.collection("visitRecords")
                        .whereField("placeID", isEqualTo: placeDocument.documentID)
                        .getDocuments()

                    for recordDocument in recordSnapshot.documents {
                        try await recordDocument.reference.delete()
                    }

                    try await placeDocument.reference.delete()
                }

                let inviteCodesSnapshot = try await db.collection("inviteCodes")
                    .whereField("spaceID", isEqualTo: spaceID)
                    .getDocuments()

                for inviteDocument in inviteCodesSnapshot.documents {
                    try await inviteDocument.reference.delete()
                }

                try await spaceDocument.reference.delete()
            }

            let placesSnapshot = try await db.collection("places")
                .whereField("addedBy", isEqualTo: userID)
                .getDocuments()

            for placeDocument in placesSnapshot.documents {
                let data = placeDocument.data()
                let spaceID = data["spaceID"] as? String

                if let spaceID, createdSpaceIDs.contains(spaceID) {
                    continue
                }

                let recordSnapshot = try await db.collection("visitRecords")
                    .whereField("placeID", isEqualTo: placeDocument.documentID)
                    .getDocuments()

                for recordDocument in recordSnapshot.documents {
                    try await recordDocument.reference.delete()
                }

                try await placeDocument.reference.delete()
            }

            let spacesSnapshot = try await db.collection("spaces")
                .whereField("memberIDs", arrayContains: userID)
                .getDocuments()

            for spaceDocument in spacesSnapshot.documents {
                if createdSpaceIDs.contains(spaceDocument.documentID) {
                    continue
                }

                try await spaceDocument.reference.updateData([
                    "memberIDs": FieldValue.arrayRemove([userID]),
                    "sharedHomeMemberIDs": FieldValue.arrayRemove([userID])
                ])
            }

            let visitRecordsSnapshot = try await db.collection("visitRecords")
                .whereField("createdBy", isEqualTo: userID)
                .getDocuments()

            for recordDocument in visitRecordsSnapshot.documents {
                let data = recordDocument.data()
                let spaceID = data["spaceID"] as? String

                if let spaceID, createdSpaceIDs.contains(spaceID) {
                    continue
                }

                try await recordDocument.reference.delete()
            }

            try await db.collection("users").document(userID).delete()
            try await firebaseUser.delete()

            self.currentUser = nil
            self.firebaseUser = nil
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            throw error
        }

        isLoading = false
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
