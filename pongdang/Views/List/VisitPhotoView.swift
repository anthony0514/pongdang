import SwiftUI

/// Shows a photo center-cropped to a square with rounded corners.
/// Pass `size: nil` to fill the available width. Remote photos go through `ThumbnailCache`.
struct VisitPhotoView: View {
    let url: URL?
    var image: UIImage?
    var size: CGFloat?
    var cornerRadius: CGFloat = 16

    /// Size the cached copy is decoded at. Full-width photos use the large detail size.
    private var cacheSize: CGFloat { size ?? Self.detailPhotoSize }
    static let detailPhotoSize: CGFloat = 240

    @State private var loadedImage: UIImage?
    @State private var didFail = false

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if let loaded = loadedImage ?? url.flatMap({ ThumbnailCache.shared.cachedImage(for: $0, pointSize: cacheSize) }) {
                    Image(uiImage: loaded)
                        .resizable()
                        .scaledToFill()
                } else if didFail {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityLabel("대표 사진")
            .task(id: url) {
                guard image == nil, let url else { return }
                didFail = false
                let result = await ThumbnailCache.shared.image(for: url, pointSize: cacheSize)
                withAnimation(.easeInOut(duration: 0.2)) {
                    loadedImage = result
                    didFail = result == nil
                }
            }
    }
}
