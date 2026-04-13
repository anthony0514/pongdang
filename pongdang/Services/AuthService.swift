import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging

extension Notification.Name {
    static let fcmRegistrationTokenDidUpdate = Notification.Name("fcmRegistrationTokenDidUpdate")
}

@MainActor
class AuthService: ObservableObject {
    private static let guestUserID = "guest-user"

    @Published var firebaseUser: FirebaseAuth.User?
    @Published var currentUser: AppUser?
    @Published var isLoading: Bool = false
    @Published var hasResolvedAuthState: Bool = false
    @Published var errorMessage: String?

    private var authStateHandle: AuthStateDidChangeListenerHandle?
    private var fcmTokenObserver: NSObjectProtocol?
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

        fcmTokenObserver = NotificationCenter.default.addObserver(
            forName: .fcmRegistrationTokenDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let token = notification.userInfo?["token"] as? String,
                !token.isEmpty
            else {
                return
            }

            Task { @MainActor in
                await self.handleFCMTokenUpdate(token)
            }
        }
    }

    deinit {
        if let handle = authStateHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
        if let fcmTokenObserver {
            NotificationCenter.default.removeObserver(fcmTokenObserver)
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
            name: "익명",
            profileImageURL: nil,
            homeAddress: nil,
            homeLatitude: nil,
            homeLongitude: nil,
            receivesNewMemberNotifications: true,
            receivesNewPlaceNotifications: true,
            receivesNewMemoNotifications: true,
            fcmTokens: [],
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
            throw NSError(
                domain: "AuthService",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "게스트 모드에서는 이름을 변경할 수 없습니다."]
            )
        }

        try await db.collection("users").document(userID).updateData([
            "name": name
        ])

        currentUser?.name = name
    }

    func updateNotificationPreferences(newMember: Bool, newPlace: Bool, newMemo: Bool) async throws {
        if isGuestUser {
            throw NSError(
                domain: "AuthService",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "게스트 모드에서는 알림 설정을 변경할 수 없습니다."]
            )
        }

        guard let userID = currentUser?.id else { return }

        try await db.collection("users").document(userID).updateData([
            "receivesNewMemberNotifications": newMember,
            "receivesNewPlaceNotifications": newPlace,
            "receivesNewMemoNotifications": newMemo
        ])

        currentUser?.receivesNewMemberNotifications = newMember
        currentUser?.receivesNewPlaceNotifications = newPlace
        currentUser?.receivesNewMemoNotifications = newMemo
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
            try ensureRecentlyAuthenticated(firebaseUser)

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
                        .whereField("spaceID", isEqualTo: spaceID)
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

                guard let spaceID else {
                    try await placeDocument.reference.delete()
                    continue
                }

                if createdSpaceIDs.contains(spaceID) {
                    continue
                }

                let recordSnapshot = try await db.collection("visitRecords")
                    .whereField("spaceID", isEqualTo: spaceID)
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

            for spaceDocument in spacesSnapshot.documents {
                let spaceID = spaceDocument.documentID

                if createdSpaceIDs.contains(spaceID) {
                    continue
                }

                let visitRecordsSnapshot = try await db.collection("visitRecords")
                    .whereField("spaceID", isEqualTo: spaceID)
                    .getDocuments()

                for recordDocument in visitRecordsSnapshot.documents {
                    let data = recordDocument.data()
                    let createdBy = data["createdBy"] as? String

                    guard createdBy == userID else { continue }
                    try await recordDocument.reference.delete()
                }
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

    private func ensureRecentlyAuthenticated(_ user: FirebaseAuth.User) throws {
        guard let lastSignInDate = user.metadata.lastSignInDate else { return }

        let allowedInterval: TimeInterval = 60 * 5
        let elapsed = Date().timeIntervalSince(lastSignInDate)

        guard elapsed <= allowedInterval else {
            throw NSError(
                domain: "AuthService",
                code: 401,
                userInfo: [
                    NSLocalizedDescriptionKey: "보안을 위해 계정 삭제 전 다시 로그인해야 합니다. 로그아웃 후 다시 로그인한 뒤 재시도해 주세요."
                ]
            )
        }
    }

    private func fetchOrCreateUser(uid: String, name: String, photoURL: String?) async {
        let ref = db.collection("users").document(uid)
        do {
            let snapshot = try await ref.getDocument()
            if snapshot.exists, let data = try? snapshot.data(as: AppUser.self) {
                self.currentUser = data
                await backfillNotificationFieldsIfNeeded(for: data)
                await syncCurrentFCMTokenIfNeeded(for: uid)
            } else {
                let newUser = AppUser(
                    id: uid,
                    name: name,
                    profileImageURL: photoURL,
                    homeAddress: nil,
                    homeLatitude: nil,
                    homeLongitude: nil,
                    receivesNewMemberNotifications: true,
                    receivesNewPlaceNotifications: true,
                    receivesNewMemoNotifications: true,
                    fcmTokens: [],
                    createdAt: Date()
                )
                try? ref.setData(from: newUser)
                self.currentUser = newUser
                await syncCurrentFCMTokenIfNeeded(for: uid)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func backfillNotificationFieldsIfNeeded(for user: AppUser) async {
        guard !isGuestUser else { return }

        var patch: [String: Any] = [:]
        patch["receivesNewMemberNotifications"] = user.receivesNewMemberNotifications
        patch["receivesNewPlaceNotifications"] = user.receivesNewPlaceNotifications
        patch["receivesNewMemoNotifications"] = user.receivesNewMemoNotifications

        if user.fcmTokens.isEmpty,
           let currentToken = Messaging.messaging().fcmToken,
           !currentToken.isEmpty {
            patch["fcmTokens"] = [currentToken]
        }

        try? await db.collection("users").document(user.id).setData(patch, merge: true)

        if let currentToken = patch["fcmTokens"] as? [String] {
            currentUser?.fcmTokens = currentToken
        }
    }

    private func syncCurrentFCMTokenIfNeeded(for userID: String) async {
        guard !isGuestUser else { return }
        guard let token = Messaging.messaging().fcmToken, !token.isEmpty else { return }
        await syncFCMToken(token, for: userID)
    }

    private func handleFCMTokenUpdate(_ token: String) async {
        guard let userID = currentUser?.id, !isGuestUser else { return }
        await syncFCMToken(token, for: userID)
    }

    private func syncFCMToken(_ token: String, for userID: String) async {
        do {
            try await db.collection("users").document(userID).updateData([
                "fcmTokens": FieldValue.arrayUnion([token])
            ])

            if currentUser?.fcmTokens.contains(token) != true {
                currentUser?.fcmTokens.append(token)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
