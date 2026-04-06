import UIKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ShareViewController

class ShareViewController: UIViewController {

    private let appGroupID = "group.anthony.pongdang"
    private let pendingShareKey = "pendingShareLocation"
    private let appURLScheme = "pongdang://addplace"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        Task {
            let location = await extractLocation()
            await MainActor.run {
                showShareUI(location: location)
            }
        }
    }

    // MARK: - Extract location from shared content

    private func extractLocation() async -> ParsedMapLocation {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem else {
            return ParsedMapLocation()
        }

        // 1. URL 타입 우선
        if let urlProvider = extensionItem.attachments?
            .first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            if let url = try? await urlProvider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                return await MapURLParser.parse(from: url.absoluteString)
            }
        }

        // 2. 텍스트 (대부분의 앱은 텍스트+URL 형태로 공유)
        if let textProvider = extensionItem.attachments?
            .first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            if let text = try? await textProvider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                return await MapURLParser.parse(from: text)
            }
        }

        return ParsedMapLocation()
    }

    // MARK: - Show SwiftUI UI

    private func showShareUI(location: ParsedMapLocation) {
        let shareView = ShareContentView(
            location: location,
            onSave: { [weak self] in
                self?.saveAndOpenApp(location: location)
            },
            onCancel: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        )

        let hosting = UIHostingController(rootView: shareView)
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hosting.didMove(toParent: self)
    }

    // MARK: - Save & Open app

    private func saveAndOpenApp(location: ParsedMapLocation) {
        // App Group UserDefaults에 저장
        if let defaults = UserDefaults(suiteName: appGroupID),
           let encoded = try? JSONEncoder().encode(location) {
            defaults.set(encoded, forKey: pendingShareKey)
            defaults.synchronize()
        }

        // pongdang 앱 열기 (Responder chain 방식 - Share Extension에서 동작)
        if let url = URL(string: appURLScheme) {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let application = next as? UIApplication {
                    application.open(url, options: [:], completionHandler: nil)
                    break
                }
                responder = next
            }
        }

        extensionContext?.completeRequest(returningItems: nil)
    }
}

// MARK: - SwiftUI View

private struct ShareContentView: View {
    let location: ParsedMapLocation
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            // 배경 딤
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            // 바텀 카드
            VStack(spacing: 0) {
                // 핸들
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 36, height: 4)
                    .padding(.top, 12)
                    .padding(.bottom, 20)

                // 헤더
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.pink)
                        Text("pongdang에 저장")
                            .font(.headline)
                    }
                    Spacer()
                    Button("취소", action: onCancel)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)

                Divider()

                // 장소 정보
                VStack(alignment: .leading, spacing: 12) {
                    if let name = location.name {
                        LabeledRow(icon: "text.alignleft", label: "장소명", value: name)
                    }

                    if let lat = location.latitude, let lng = location.longitude {
                        LabeledRow(
                            icon: "location.fill",
                            label: "좌표",
                            value: String(format: "%.5f, %.5f", lat, lng)
                        )
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("좌표를 찾지 못했어요. 저장 후 직접 조정할 수 있어요.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    if let url = location.sourceURL {
                        LabeledRow(icon: "link", label: "출처", value: url)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 20)

                Divider()

                // 저장 버튼
                Button(action: onSave) {
                    Text("pongdang에 추가")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.pink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.background)
            )
        }
        .ignoresSafeArea()
    }
}

private struct LabeledRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
                    .lineLimit(2)
            }
        }
    }
}
