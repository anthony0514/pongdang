import SwiftUI

/// Shows a photo center-cropped to a square with rounded corners.
/// Pass `size: nil` to fill the available width.
struct VisitPhotoView: View {
    let url: URL?
    var image: UIImage?
    var size: CGFloat?
    var cornerRadius: CGFloat = 16

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                        switch phase {
                        case .success(let loaded):
                            loaded
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        default:
                            ProgressView()
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityLabel("대표 사진")
    }
}
