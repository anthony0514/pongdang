import UIKit

enum ImageCompressor {
    /// Downscales so the longer side is at most `maxDimension` and re-encodes as JPEG.
    /// A typical phone photo ends up around 300-600KB.
    static func jpegData(from data: Data, maxDimension: CGFloat = 2048, quality: CGFloat = 0.8) -> Data? {
        guard let image = UIImage(data: data) else { return nil }

        let longestSide = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / longestSide)
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        // Drawing also bakes in the EXIF orientation, so the upload is always upright.
        let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        return resized.jpegData(compressionQuality: quality)
    }
}
