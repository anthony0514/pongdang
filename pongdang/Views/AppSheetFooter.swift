import SwiftUI

struct AppSheetFooter: View {
    @State private var showingBrandOverlay = false

    var body: some View {
        Button {
            showingBrandOverlay = true
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
        .fullScreenCover(isPresented: $showingBrandOverlay) {
            ZStack {
                DesignSystem.Backgrounds.lakeGradient
                    .ignoresSafeArea()
                    .onTapGesture {
                        showingBrandOverlay = false
                    }

                Image("app_logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .shadow(color: Color.black.opacity(0.18), radius: 22, y: 10)
                    .onTapGesture {
                        showingBrandOverlay = false
                    }
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
