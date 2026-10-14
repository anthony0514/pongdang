import SwiftUI

/// Builds a story-sized image (card on a blurred copy of the photo) and shares it
/// through the system share sheet, where Instagram Stories, KakaoTalk, Photos, etc. all appear.
struct VisitShareSheet: View {
    struct SharedComment: Hashable {
        let authorName: String
        let body: String
    }

    let visit: VisitRecord
    /// Comments with text, oldest first.
    let comments: [SharedComment]

    @State private var shareImage: UIImage?
    @State private var photo: UIImage?
    @State private var hasLoadedPhoto = false
    @State private var includesComments = false

    var body: some View {
        ShareImageScaffold(title: visit.placeName, image: shareImage) {
            if !comments.isEmpty {
                Toggle("댓글 보기", isOn: $includesComments)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 24)
            }
        }
        .task(id: includesComments) {
            await buildShareImage()
        }
    }

    private func buildShareImage() async {
        // Download once; toggling comments only re-renders.
        if !hasLoadedPhoto {
            if let urlString = visit.photoURL, let url = URL(string: urlString),
               let (data, _) = try? await URLSession.shared.data(from: url) {
                photo = UIImage(data: data)
            }
            hasLoadedPhoto = true
        }

        let renderer = ImageRenderer(content: VisitShareStory(
            visit: visit,
            photo: photo,
            comments: includesComments ? comments : []
        ))
        renderer.scale = ShareStoryBackground.renderScale
        shareImage = renderer.uiImage
    }
}

/// The full 9:16 share image: the card floating over a blurred, darkened copy of its photo.
struct VisitShareStory: View {
    let visit: VisitRecord
    let photo: UIImage?
    let comments: [VisitShareSheet.SharedComment]

    var body: some View {
        ZStack {
            ShareStoryBackground(photo: photo)

            VisitShareCard(visit: visit, photo: photo, comments: comments)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)

            ShareStoryBadge()
                .frame(width: ShareStoryBackground.size.width, height: ShareStoryBackground.size.height, alignment: .bottomTrailing)
        }
        .frame(width: ShareStoryBackground.size.width, height: ShareStoryBackground.size.height)
        .clipped()
        .environment(\.colorScheme, .light)
    }
}

/// The card itself. Always rendered in light mode so it looks the same everywhere.
struct VisitShareCard: View {
    static let fallbackGradient = LinearGradient(
        colors: [Color(red: 0.03, green: 0.14, blue: 0.24), Color(red: 0.37, green: 0.73, blue: 0.90)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    let visit: VisitRecord
    let photo: UIImage?
    let comments: [VisitShareSheet.SharedComment]

    private static let maxComments = 3
    private let width: CGFloat = 272

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            photoArea
                .frame(width: width, height: width)
                .clipped()

            VStack(alignment: .leading, spacing: 6) {
                Text(visit.placeName)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.black)
                    .lineLimit(2)

                Text(Self.dateFormatter.string(from: visit.visitedAt))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(white: 0.45))

                if !comments.isEmpty {
                    commentList
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 18)
        }
        .frame(width: width)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var commentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(Color(white: 0.9))
                .frame(height: 1)

            ForEach(comments.prefix(Self.maxComments), id: \.self) { comment in
                (Text(comment.authorName).fontWeight(.bold) + Text("  ") + Text(comment.body))
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: 0.2))
                    .lineLimit(2)
            }

            if comments.count > Self.maxComments {
                Text("외 \(comments.count - Self.maxComments)개")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(white: 0.5))
            }
        }
    }

    @ViewBuilder
    private var photoArea: some View {
        if let photo {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
        } else {
            Self.fallbackGradient
                .overlay {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 60, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy.MM.dd (E)"
        return formatter
    }()
}

/// Preview of a share image with a share button. `controls` go between them.
struct ShareImageScaffold<Controls: View>: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let image: UIImage?
    @ViewBuilder let controls: Controls

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 8)

                controls

                if let image {
                    Button {
                        SystemShare.present(image: image, message: AppLinks.shareMessageText)
                    } label: {
                        Label("공유하기", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
            }
            .navigationTitle("공유")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}

/// Story-sized backdrop: a blurred, darkened photo, or the app gradient without one.
struct ShareStoryBackground: View {
    /// 360x640pt rendered at 3x is 1080x1920px, the Instagram story size.
    static let size = CGSize(width: 360, height: 640)
    static let renderScale: CGFloat = 3

    let photo: UIImage?

    var body: some View {
        if let photo {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: Self.size.width, height: Self.size.height)
                // Scale up so the blur's soft edges fall outside the frame.
                .scaleEffect(1.3)
                .blur(radius: 28)
                .overlay(Color.black.opacity(0.18))
        } else {
            VisitShareCard.fallbackGradient
        }
    }
}

/// The app icon in the story's bottom-right corner.
struct ShareStoryBadge: View {
    var body: some View {
        Image("app_icon")
            .resizable()
            .scaledToFill()
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
            .padding(.trailing, 16)
            .padding(.bottom, 8)
    }
}

enum AppLinks {
    /// App Store page, attached as text when sharing so recipients can tap through.
    static let appStoreURL: URL? = URL(string: "https://apps.apple.com/kr/app/pongdang/id6761649070")

    static var shareMessageText: String? {
        appStoreURL.map { "퐁당에서 기록했어요 \($0.absoluteString)" }
    }
}

/// Presents the system share sheet. Instagram's share extension rejects shares that carry
/// text along with the image ("현재 콘텐츠를 볼 수 없습니다"), so the link text is
/// withheld from Instagram and only sent to other apps.
enum SystemShare {
    @MainActor
    static func present(image: UIImage, message: String?) {
        var items: [Any] = [image]
        if let message {
            items.append(MessageItem(message: message))
        }

        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        guard let presenter = topViewController() else { return }
        // iPad shows the share sheet as a popover, which needs an anchor.
        controller.popoverPresentationController?.sourceView = presenter.view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 80, width: 0, height: 0
        )
        presenter.present(controller, animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    private final class MessageItem: NSObject, UIActivityItemSource {
        let message: String

        init(message: String) {
            self.message = message
        }

        func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
            message
        }

        func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
            let identifier = activityType?.rawValue.lowercased() ?? ""
            if identifier.contains("instagram") || identifier.contains("burbn") {
                return nil
            }
            return message
        }
    }
}
