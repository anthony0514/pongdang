import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let appGroupID = "group.anthony.pongdang"
    private let pendingShareKey = "pendingShareLocation"
    private let appURLScheme = "pongdang://addplace"
    private var didStartForwarding = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !didStartForwarding else { return }
        didStartForwarding = true

        Task {
            let location = await extractLocation()
            saveToAppGroup(location)
            openMainApp()
        }
    }

    private func extractLocation() async -> ParsedMapLocation {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            return ParsedMapLocation()
        }

        var merged = ParsedMapLocation()

        for extensionItem in extensionItems {
            for provider in extensionItem.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await loadText(from: provider, typeIdentifier: UTType.plainText.identifier) {
                    merged = merge(merged, with: await MapURLParser.parse(from: text))
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
                   let text = try? await loadText(from: provider, typeIdentifier: UTType.text.identifier) {
                    merged = merge(merged, with: await MapURLParser.parse(from: text))
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await loadURL(from: provider) {
                    merged = merge(merged, with: await MapURLParser.parse(from: url.absoluteString))
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   merged.hasCoordinates,
                   merged.name != nil {
                    return merged
                }
            }
        }

        return merged
    }

    private func loadURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: NSError(domain: "ShareExtension", code: 0))
                }
            }
        }
    }

    private func loadText(from provider: NSItemProvider, typeIdentifier: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let text = item as? String {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: NSError(domain: "ShareExtension", code: 1))
                }
            }
        }
    }

    private func saveToAppGroup(_ location: ParsedMapLocation) {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let encoded = try? JSONEncoder().encode(location) else {
            return
        }

        defaults.set(encoded, forKey: pendingShareKey)
        defaults.synchronize()
    }

    private func openMainApp() {
        guard let url = URL(string: appURLScheme) else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        extensionContext?.open(url) { [weak self] _ in
            guard let self else { return }
            self.openURLViaResponderChain(url)
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func openURLViaResponderChain(_ url: URL) {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let application = next as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = next
        }
    }

    private func merge(_ lhs: ParsedMapLocation, with rhs: ParsedMapLocation) -> ParsedMapLocation {
        ParsedMapLocation(
            name: lhs.name ?? rhs.name,
            latitude: lhs.latitude ?? rhs.latitude,
            longitude: lhs.longitude ?? rhs.longitude,
            address: lhs.address ?? rhs.address,
            sourceURL: lhs.sourceURL ?? rhs.sourceURL
        )
    }
}
