import SwiftUI

enum DesignSystem {
    enum Colors {
        static let backgroundTop    = Color(hex: "08243D")
        static let backgroundMid    = Color(hex: "0D3B66")
        static let backgroundBottom = Color(hex: "5FB9E5")
        static let mist             = Color.white.opacity(0.30)
        static let cardHighlight    = Color(hex: "BDEBFF").opacity(0.24)
        static let cardShadow       = Color.black.opacity(0.22)
        static let primary          = Color(hex: "2F7FB8")
        static let accent           = Color(hex: "7FDBFF")
        static let visited          = Color(hex: "70E0C2")
        static let textPrimary      = Color(hex: "EAF8FF")
        static let textSecondary    = Color(hex: "B8D8EA")
        static let border           = Color.white.opacity(0.22)
    }

    enum Radius {
        static let small:  CGFloat = 12
        static let medium: CGFloat = 18
        static let large:  CGFloat = 24
    }

    enum Backgrounds {
        static let lakeGradient = LinearGradient(
            colors: [
                Colors.backgroundTop,
                Colors.backgroundMid,
                Colors.backgroundBottom
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let lakeGlow = RadialGradient(
            colors: [
                Color(hex: "C8F1FF").opacity(0.55),
                Color.white.opacity(0.0)
            ],
            center: .topLeading,
            startRadius: 20,
            endRadius: 420
        )
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension View {
    func pondangScreenBackground() -> some View {
        fontDesign(.rounded)
            .background(
                ZStack {
                    DesignSystem.Backgrounds.lakeGradient
                    DesignSystem.Backgrounds.lakeGlow
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.06),
                            Color.clear,
                            Color(hex: "041827").opacity(0.18)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
            )
    }

    func pondangGlassCard(cornerRadius: CGFloat = DesignSystem.Radius.large) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    DesignSystem.Colors.cardHighlight,
                                    Color.white.opacity(0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(DesignSystem.Colors.border, lineWidth: 1)
                )
                .shadow(color: DesignSystem.Colors.cardShadow, radius: 18, y: 10)
        )
    }
}
