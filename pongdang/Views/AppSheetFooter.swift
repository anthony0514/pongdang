import SwiftUI

struct AppSheetFooter: View {
    @State private var activeEasterEgg: EasterEggStyle?

    var body: some View {
        Button {
            activeEasterEgg = .brand
        } label: {
            VStack(spacing: 8) {
                Image("app_logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)

                Text("Pongdang")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(appVersionText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text("Anthony")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .fullScreenCover(item: $activeEasterEgg) { style in
            EasterEggOverlay(style: style) {
                activeEasterEgg = nil
            }
        }
    }

    private var appVersionText: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, buildNumber) {
        case let (shortVersion?, buildNumber?) where !shortVersion.isEmpty && !buildNumber.isEmpty:
            return "v\(shortVersion) (\(buildNumber))"
        case let (shortVersion?, _) where !shortVersion.isEmpty:
            return "v\(shortVersion)"
        case let (_, buildNumber?) where !buildNumber.isEmpty:
            return "build \(buildNumber)"
        default:
            return "v1.0"
        }
    }
}
