import Foundation
import Combine
import FirebaseFirestore

@MainActor
final class PlaceService: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let db = Firestore.firestore()

    func addPlace(_ place: Place) async throws {
        isLoading = true
        errorMessage = nil

        do {
            try await db.collection("places").document(place.id).setData(data(for: place))
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            throw error
        }
    }

    func updatePlace(_ place: Place) async throws {
        isLoading = true
        errorMessage = nil

        do {
            try await db.collection("places").document(place.id).setData(data(for: place), merge: true)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            throw error
        }
    }

    func deletePlace(id: String) async throws {
        isLoading = true
        errorMessage = nil

        do {
            let recordSnapshot = try await db.collection("visitRecords")
                .whereField("placeID", isEqualTo: id)
                .getDocuments()

            for document in recordSnapshot.documents {
                try await document.reference.delete()
            }

            try await db.collection("places").document(id).delete()
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            throw error
        }
    }

    func markVisited(placeID: String) async throws {
        isLoading = true
        errorMessage = nil

        do {
            try await db.collection("places").document(placeID).updateData([
                "isVisited": true
            ])
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            throw error
        }
    }

    private func data(for place: Place) -> [String: Any] {
        [
            "id": place.id,
            "spaceID": place.spaceID,
            "name": place.name,
            "address": place.address,
            "latitude": place.latitude,
            "longitude": place.longitude,
            "category": place.category.rawValue,
            "tags": place.tags,
            "memo": place.memo as Any,
            "addedBy": place.addedBy,
            "addedAt": Timestamp(date: place.addedAt),
            "isVisited": place.isVisited
        ]
    }
}
