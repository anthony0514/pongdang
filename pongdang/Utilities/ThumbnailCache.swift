import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/// Downsampled copies of remote photos, kept in memory for the app's lifetime so list rows,
/// map pins, and detail photos don't re-download full-size images. Nothing is written to disk.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        memory.countLimit = 300
        // Downsampled images, so this is a few tens of MB at most. NSCache also frees memory under pressure.
        memory.totalCostLimit = 80 * 1024 * 1024
    }

    /// Returns a thumbnail already in memory, without any I/O.
    func cachedImage(for url: URL, pointSize: CGFloat) -> UIImage? {
        memory.object(forKey: key(for: url, pointSize: pointSize) as NSString)
    }

    func image(for url: URL, pointSize: CGFloat) async -> UIImage? {
        let key = key(for: url, pointSize: pointSize)
        if let image = memory.object(forKey: key as NSString) {
            return image
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let pixelSize = pointSize * UITraitCollection.current.displayScale
        let task = Task<UIImage?, Never>.detached(priority: .utility) {
            guard
                let (data, _) = try? await URLSession.shared.data(from: url),
                let image = Self.downsample(data, maxPixelSize: pixelSize)
            else { return nil }
            return image
        }

        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            memory.setObject(image, forKey: key as NSString, cost: cost)
        }
        return image
    }

    private func key(for url: URL, pointSize: CGFloat) -> String {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(hash.prefix(32))_\(Int(pointSize))"
    }

    /// Decodes straight to the target size, which uses far less memory than
    /// decoding the full photo and scaling it down.
    nonisolated private static func downsample(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            // Max size applies to the long side; a little headroom keeps the short side sharp after square cropping.
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize * 1.5
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// A square, rounded thumbnail backed by `ThumbnailCache`.
struct CachedThumbnail: View {
    let url: URL?
    let size: CGFloat
    var cornerRadius: CGFloat = 10

    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .frame(width: size, height: size)
            .overlay {
                if let image = image ?? url.flatMap({ ThumbnailCache.shared.cachedImage(for: $0, pointSize: size) }) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: url) {
                guard let url else { return }
                image = await ThumbnailCache.shared.image(for: url, pointSize: size)
            }
    }
}
