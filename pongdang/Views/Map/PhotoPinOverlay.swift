import Observation
import SwiftUI

/// Lays out visit photos above their pins with a small spring simulation:
/// each photo is pulled back over its own pin and pushed away from photos
/// (and pins) it overlaps, so crowded photos squish aside instead of hiding.
///
/// Positions are stored as offsets from each pin, so panning moves photos
/// rigidly with the map and only zooming makes them jostle. The simulation
/// only ticks while something is moving and goes idle once everything settles.
@MainActor
@Observable
final class PhotoPinSimulator {
    struct Node {
        let placeID: String
        var url: URL
        var pin: CGPoint
        var offset: CGVector = .zero
        var velocity: CGVector = .zero
        var isOnScreen = false

        /// Rest position: centered right above the pin.
        var home: CGPoint {
            CGPoint(x: pin.x, y: pin.y - PhotoPinSimulator.lift)
        }

        var position: CGPoint {
            CGPoint(x: home.x + offset.dx, y: home.y + offset.dy)
        }
    }

    static let photoSize: CGFloat = 44
    static let pinSize: CGFloat = 24
    static let lift = photoSize / 2 + pinSize / 2 + 6

    // Tuning. Slightly under-damped so photos wobble a little before settling.
    private static let spring: CGFloat = 140
    private static let damping: CGFloat = 15
    private static let photoPush: CGFloat = 900
    private static let pinPush: CGFloat = 450
    private static let photoSpacing: CGFloat = 4
    private static let maxOffset: CGFloat = 160
    private static let restSpeed: CGFloat = 3

    /// Drives the overlay's timeline; it pauses when false.
    private(set) var isRunning = false
    /// Thumbnails by place ID, loaded by the overlay.
    var images: [String: UIImage] = [:]
    /// Bumped when the set of photos changes, so the overlay reloads thumbnails.
    private(set) var photoSetVersion = 0

    @ObservationIgnored private(set) var nodes: [Node] = []
    @ObservationIgnored private var obstacles: [CGPoint] = []
    @ObservationIgnored private var bounds: CGRect = .zero
    @ObservationIgnored private var lastStep: Date?
    @ObservationIgnored private var framesSinceUpdate = 0

    /// - Parameters:
    ///   - photos: Places with a photo, most recent visit first (drawn on top).
    ///   - pinCenters: Screen position of every place's pin.
    func update(photos: [(placeID: String, url: URL)], pinCenters: [String: CGPoint], bounds: CGRect) {
        self.bounds = bounds
        let previous = Dictionary(nodes.map { ($0.placeID, $0) }, uniquingKeysWith: { first, _ in first })

        nodes = photos.compactMap { photo in
            guard let pin = pinCenters[photo.placeID] else { return nil }
            var node = previous[photo.placeID] ?? Node(placeID: photo.placeID, url: photo.url, pin: pin)
            node.url = photo.url
            node.pin = pin
            return node
        }
        if Set(nodes.map(\.url)) != Set(previous.values.map(\.url)) {
            photoSetVersion += 1
        }
        obstacles = Array(pinCenters.values)
        framesSinceUpdate = 0
        wake()
    }

    func wake() {
        guard !isRunning else { return }
        lastStep = nil
        isRunning = true
    }

    /// The top-most photo under a point, for taps.
    func placeID(at point: CGPoint) -> String? {
        let half = Self.photoSize / 2
        return nodes.first { node in
            node.isOnScreen && abs(node.position.x - point.x) <= half && abs(node.position.y - point.y) <= half
        }?.placeID
    }

    func step(now: Date) {
        guard isRunning else { return }
        let dt = min(now.timeIntervalSince(lastStep ?? now), 1.0 / 30)
        lastStep = now
        framesSinceUpdate += 1

        let visibleArea = bounds.insetBy(dx: -Self.photoSize * 2, dy: -Self.photoSize * 2)
        for index in nodes.indices {
            nodes[index].isOnScreen = visibleArea.contains(nodes[index].home)
        }
        let active = nodes.indices.filter { nodes[$0].isOnScreen }

        if dt > 0 {
            // Two half steps keep the springs stable when a frame runs long.
            for _ in 0..<2 {
                integrate(active: active, dt: CGFloat(dt) / 2)
            }
        }

        let maxSpeed = active.map { hypot(nodes[$0].velocity.dx, nodes[$0].velocity.dy) }.max() ?? 0
        if framesSinceUpdate > 2 && maxSpeed < Self.restSpeed {
            for index in active {
                nodes[index].velocity = .zero
            }
            // Changing observed state during rendering is not allowed, so defer it.
            Task { @MainActor in self.isRunning = false }
        }
    }

    private func integrate(active: [Int], dt: CGFloat) {
        var forces = [CGVector](repeating: .zero, count: nodes.count)
        let size = Self.photoSize + Self.photoSpacing

        for i in active {
            // Pull back toward the pin, with damping.
            forces[i].dx = -Self.spring * nodes[i].offset.dx - Self.damping * nodes[i].velocity.dx
            forces[i].dy = -Self.spring * nodes[i].offset.dy - Self.damping * nodes[i].velocity.dy

            // Step off other pins the photo would cover.
            let position = nodes[i].position
            let reach = Self.photoSize / 2 + Self.pinSize / 2
            for pin in obstacles where pin != nodes[i].pin {
                let dx = position.x - pin.x
                let dy = position.y - pin.y
                guard abs(dx) < reach, abs(dy) < reach else { continue }
                let penetration = reach - max(abs(dx), abs(dy))
                let direction = Self.direction(dx: dx, dy: dy)
                forces[i].dx += direction.dx * penetration * Self.pinPush
                forces[i].dy += direction.dy * penetration * Self.pinPush
            }
        }

        // Push overlapping photos apart.
        for (a, i) in active.enumerated() {
            for j in active[(a + 1)...] {
                let dx = nodes[i].position.x - nodes[j].position.x
                let dy = nodes[i].position.y - nodes[j].position.y
                let overlapX = size - abs(dx)
                let overlapY = size - abs(dy)
                guard overlapX > 0, overlapY > 0 else { continue }

                let push = min(overlapX, overlapY) * Self.photoPush
                let direction = Self.direction(dx: dx, dy: dy)
                forces[i].dx += direction.dx * push
                forces[i].dy += direction.dy * push
                forces[j].dx -= direction.dx * push
                forces[j].dy -= direction.dy * push
            }
        }

        for i in active {
            nodes[i].velocity.dx += forces[i].dx * dt
            nodes[i].velocity.dy += forces[i].dy * dt
            nodes[i].offset.dx += nodes[i].velocity.dx * dt
            nodes[i].offset.dy += nodes[i].velocity.dy * dt

            let length = hypot(nodes[i].offset.dx, nodes[i].offset.dy)
            if length > Self.maxOffset {
                nodes[i].offset.dx *= Self.maxOffset / length
                nodes[i].offset.dy *= Self.maxOffset / length
            }
        }
    }

    /// Unit vector for a separation. Exactly stacked photos get a stable sideways nudge.
    private static func direction(dx: CGFloat, dy: CGFloat) -> CGVector {
        let length = hypot(dx, dy)
        guard length > 0.01 else { return CGVector(dx: 1, dy: 0) }
        return CGVector(dx: dx / length, dy: dy / length)
    }
}

/// Draws every photo pin in one Canvas on top of the map. Taps pass through to the map.
struct PhotoPinOverlay: View {
    let simulator: PhotoPinSimulator

    var body: some View {
        TimelineView(.animation(paused: !simulator.isRunning)) { timeline in
            Canvas { context, _ in
                simulator.step(now: timeline.date)
                draw(in: &context)
            }
        }
        .allowsHitTesting(false)
        .task(id: simulator.photoSetVersion) {
            await loadThumbnails()
        }
    }

    private func draw(in context: inout GraphicsContext) {
        let size = PhotoPinSimulator.photoSize
        let corner: CGFloat = 10
        // Most recent visit is first in the list, so draw in reverse to keep it on top.
        let nodes = simulator.nodes.reversed().filter(\.isOnScreen)

        // Tethers from displaced photos back to their pins.
        var tethers = Path()
        for node in nodes where hypot(node.offset.dx, node.offset.dy) > 6 {
            tethers.move(to: CGPoint(x: node.pin.x, y: node.pin.y - PhotoPinSimulator.pinSize / 2))
            tethers.addLine(to: CGPoint(x: node.position.x, y: node.position.y + size / 2))
        }
        context.stroke(tethers, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round))

        // One shared shadow layer instead of a shadow per photo.
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.25), radius: 4, y: 2))
            for node in nodes {
                let rect = CGRect(x: node.position.x - size / 2, y: node.position.y - size / 2, width: size, height: size)
                let shape = Path(roundedRect: rect, cornerRadius: corner, style: .continuous)

                layer.fill(shape, with: .color(.white))
                layer.drawLayer { photoLayer in
                    let inner = rect.insetBy(dx: 2, dy: 2)
                    photoLayer.clip(to: Path(roundedRect: inner, cornerRadius: corner - 2, style: .continuous))
                    if let image = simulator.images[node.placeID] {
                        photoLayer.draw(Image(uiImage: image), in: Self.aspectFill(image.size, into: inner))
                    } else {
                        photoLayer.fill(Path(inner), with: .color(Color(.systemGray5)))
                    }
                }
            }
        }
    }

    private func loadThumbnails() async {
        for node in simulator.nodes where simulator.images[node.placeID] == nil {
            if let image = await ThumbnailCache.shared.image(for: node.url, pointSize: PhotoPinSimulator.photoSize) {
                simulator.images[node.placeID] = image
                simulator.wake()
            }
        }
    }

    private static func aspectFill(_ imageSize: CGSize, into rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
}
