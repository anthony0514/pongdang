import FirebaseFirestore

enum UserNameLoader {
    /// Fetches display names for the given user IDs, skipping ones already known.
    static func loadNames(
        for userIDs: some Sequence<String>,
        excluding known: [String: String]
    ) async -> [String: String] {
        var names: [String: String] = [:]

        for userID in Set(userIDs) where known[userID] == nil {
            names[userID] = await name(for: userID)
        }

        return names
    }

    static func name(for userID: String) async -> String {
        let fallback = userID == "guest-user" ? "익명" : "알 수 없음"

        guard let snapshot = try? await Firestore.firestore()
            .collection("users")
            .document(userID)
            .getDocument(),
            let name = snapshot.data()?["name"] as? String,
            !name.isEmpty
        else {
            return fallback
        }

        return name
    }
}
