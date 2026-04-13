import Foundation
import Combine
import FirebaseFirestore

@MainActor
final class PlaceService: ObservableObject {
    private static let guestUserID = "guest-user"

    @Published var isLoading = false
    @Published var errorMessage: String?

    private let db = Firestore.firestore()

    func addPlace(_ place: Place, requestedBy requesterID: String) async throws {
        isLoading = true
        errorMessage = nil

        do {
            try ensureWritableUser(requesterID)
            guard requesterID == place.addedBy else {
                throw Self.makeError("장소 추가 요청이 올바르지 않습니다")
            }
            try await ensureMember(spaceID: place.spaceID, requesterID: requesterID)
            try await db.collection("places").document(place.id).setData(data(for: place))
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            throw error
        }
    }

    func updatePlace(_ place: Place, requestedBy requesterID: String) async throws {
        isLoading = true
        errorMessage = nil

        do {
            try ensureWritableUser(requesterID)
            try await ensureMember(spaceID: place.spaceID, requesterID: requesterID)
            let existingPlace = try await fetchPlace(id: place.id)
            let ownerID = try await ownerID(for: place.spaceID)

            guard requesterID == existingPlace.addedBy || requesterID == ownerID else {
                throw Self.makeError("장소를 수정할 권한이 없습니다")
            }

            try await db.collection("places").document(place.id).updateData(updateData(for: place))
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            throw error
        }
    }

    func deletePlace(id: String, requestedBy requesterID: String) async throws {
        isLoading = true
        errorMessage = nil

        do {
            try ensureWritableUser(requesterID)
            let existingPlace = try await fetchPlace(id: id)
            try await ensureMember(spaceID: existingPlace.spaceID, requesterID: requesterID)
            let ownerID = try await ownerID(for: existingPlace.spaceID)

            guard requesterID == existingPlace.addedBy || requesterID == ownerID else {
                throw Self.makeError("장소를 삭제할 권한이 없습니다")
            }

            let recordSnapshot = try await db.collection("visitRecords")
                .whereField("spaceID", isEqualTo: existingPlace.spaceID)
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

    func markVisited(placeID: String, requestedBy requesterID: String) async throws {
        isLoading = true
        errorMessage = nil

        do {
            try ensureWritableUser(requesterID)
            let existingPlace = try await fetchPlace(id: placeID)
            try await ensureMember(spaceID: existingPlace.spaceID, requesterID: requesterID)
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
            "sourceURL": place.sourceURL as Any,
            "addedBy": place.addedBy,
            "addedAt": Timestamp(date: place.addedAt),
            "isVisited": place.isVisited
        ]
    }

    private func updateData(for place: Place) -> [String: Any] {
        [
            "name": place.name,
            "address": place.address,
            "latitude": place.latitude,
            "longitude": place.longitude,
            "category": place.category.rawValue,
            "tags": place.tags,
            "memo": place.memo as Any,
            "sourceURL": place.sourceURL as Any,
            "isVisited": place.isVisited
        ]
    }

    private func ensureWritableUser(_ requesterID: String) throws {
        guard !requesterID.isEmpty, requesterID != Self.guestUserID else {
            throw Self.makeError("게스트 모드에서는 이 작업을 할 수 없습니다")
        }
    }

    private func ensureMember(spaceID: String, requesterID: String) async throws {
        let snapshot = try await db.collection("spaces").document(spaceID).getDocument()
        guard
            snapshot.exists,
            let memberIDs = snapshot.data()?["memberIDs"] as? [String]
        else {
            throw Self.makeError("스페이스를 찾을 수 없습니다")
        }

        guard memberIDs.contains(requesterID) else {
            throw Self.makeError("이 스페이스에 접근할 권한이 없습니다")
        }
    }

    private func ownerID(for spaceID: String) async throws -> String {
        let snapshot = try await db.collection("spaces").document(spaceID).getDocument()
        guard
            snapshot.exists,
            let createdBy = snapshot.data()?["createdBy"] as? String
        else {
            throw Self.makeError("스페이스를 찾을 수 없습니다")
        }

        return createdBy
    }

    private func fetchPlace(id: String) async throws -> Place {
        let snapshot = try await db.collection("places").document(id).getDocument()
        guard
            snapshot.exists,
            let data = snapshot.data(),
            let spaceID = data["spaceID"] as? String,
            let name = data["name"] as? String,
            let address = data["address"] as? String,
            let latitude = data["latitude"] as? Double,
            let longitude = data["longitude"] as? Double,
            let categoryRaw = data["category"] as? String,
            let category = PlaceCategory(rawValue: categoryRaw),
            let addedBy = data["addedBy"] as? String,
            let addedAt = (data["addedAt"] as? Timestamp)?.dateValue(),
            let isVisited = data["isVisited"] as? Bool
        else {
            throw Self.makeError("장소를 찾을 수 없습니다")
        }

        return Place(
            id: snapshot.documentID,
            spaceID: spaceID,
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude,
            category: category,
            tags: data["tags"] as? [String] ?? [],
            memo: data["memo"] as? String,
            sourceURL: data["sourceURL"] as? String,
            addedBy: addedBy,
            addedAt: addedAt,
            isVisited: isVisited
        )
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "PlaceService", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
