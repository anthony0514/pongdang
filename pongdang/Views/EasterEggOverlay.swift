import SwiftUI

enum EasterEggStyle: Identifiable, Equatable {
    case brand

    var id: String { "brand" }
}

struct EasterEggOverlay: View {
    let style: EasterEggStyle
    let onDismiss: () -> Void

    @State private var heartBursts: [HeartBurst] = []

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                DesignSystem.Backgrounds.lakeGradient
                    .ignoresSafeArea()
                    .onTapGesture {
                        onDismiss()
                    }

                DesignSystem.Backgrounds.lakeGlow
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                ForEach(heartBursts) { burst in
                    FloatingHeartView(
                        burst: burst,
                        origin: CGPoint(
                            x: proxy.size.width / 2,
                            y: proxy.size.height / 2 + 10
                        )
                    )
                }

                Image("app_logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .shadow(color: Color.black.opacity(0.18), radius: 22, y: 10)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        launchHeartBurst()
                    }
            }
            .onDisappear {
                heartBursts.removeAll()
            }
        }
    }

    private func launchHeartBurst() {
        let newBursts = (0..<Int.random(in: 10...15)).map { _ in
            HeartBurst(
                xOffset: CGFloat.random(in: -54...54),
                drift: CGFloat.random(in: -90...90),
                rise: CGFloat.random(in: 190...330),
                size: CGFloat.random(in: 18...34),
                rotation: Double.random(in: -26...26),
                duration: Double.random(in: 1.5...2.4),
                delay: Double.random(in: 0...0.24),
                hueShift: Double.random(in: -0.04...0.08)
            )
        }

        heartBursts.append(contentsOf: newBursts)

        Task { @MainActor in
            let longestLifetime = newBursts.map { $0.duration + $0.delay }.max() ?? 0
            try? await Task.sleep(for: .seconds(longestLifetime + 0.2))
            let expiredIDs = Set(newBursts.map(\.id))
            heartBursts.removeAll { expiredIDs.contains($0.id) }
        }
    }
}

private struct HeartBurst: Identifiable {
    let id = UUID()
    let xOffset: CGFloat
    let drift: CGFloat
    let rise: CGFloat
    let size: CGFloat
    let rotation: Double
    let duration: Double
    let delay: Double
    let hueShift: Double
}

private struct FloatingHeartView: View {
    let burst: HeartBurst
    let origin: CGPoint

    @State private var isAnimating = false

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: burst.size, weight: .semibold))
            .foregroundStyle(heartGradient)
            .shadow(color: Color.white.opacity(0.24), radius: 10, y: 0)
            .shadow(color: Color(hex: "0F5D8C").opacity(0.22), radius: 14, y: 8)
            .scaleEffect(isAnimating ? 1 : 0.35)
            .rotationEffect(.degrees(isAnimating ? burst.rotation : 0))
            .opacity(isAnimating ? 0 : 1)
            .offset(
                x: burst.xOffset + (isAnimating ? burst.drift : 0),
                y: isAnimating ? -burst.rise : 0
            )
            .position(origin)
            .allowsHitTesting(false)
            .task {
                guard !isAnimating else { return }
                try? await Task.sleep(for: .seconds(burst.delay))
                withAnimation(.easeOut(duration: burst.duration)) {
                    isAnimating = true
                }
            }
    }

    private var heartGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 1, green: min(max(0.40 + burst.hueShift, 0), 1), blue: 0.70),
                Color(red: 1, green: 0.74, blue: min(max(0.84 + burst.hueShift, 0), 1))
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
