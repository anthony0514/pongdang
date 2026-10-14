import FirebaseStorage
import Foundation

enum PhotoStorage {
    /// Uploads a JPEG into `folder` under a new file name.
    /// Returns the download URL and the storage path (kept so the file can be deleted later).
    static func upload(_ jpegData: Data, folder: String) async throws -> (url: String, path: String) {
        let path = "\(folder)/\(UUID().uuidString).jpg"
        let reference = Storage.storage().reference(withPath: path)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        _ = try await reference.putDataAsync(jpegData, metadata: metadata)
        let downloadURL = try await reference.downloadURL()
        return (downloadURL.absoluteString, path)
    }

    /// Best effort: a leftover file only costs storage, so failures are ignored.
    static func delete(at path: String?) async {
        guard let path, !path.isEmpty else { return }
        try? await Storage.storage().reference(withPath: path).delete()
    }
}
